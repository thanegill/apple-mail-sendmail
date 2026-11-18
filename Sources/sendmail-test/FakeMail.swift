import ApplicationServices
import Foundation
import SendmailCore

/// A state machine standing in for Mail, its Accessibility tree, Launch
/// Services and the clock, so `AXEmlDelivery` runs without a real Mail.
///
/// Like Mail, a menu press acts on the key (focused) window, and only while
/// Mail is frontmost: Send Again on a viewer opens a compose; Send Again or
/// Send on a compose sends it. Send Again is enabled only while a viewer is
/// key and Send only while a compose is, so the two never share the
/// shift-cmd-D shortcut while both are enabled. Time advances only when the
/// code under test sleeps.
final class FakeMail: AXClient, MailWorkspace, Clock {
    enum Node: Hashable {
        case app
        case window(Int)
        case closeButton(Int)
        case sheet(Int)
        case menuBar
        case menuBarItem(Int)
        case menu(Int)
        case menuItem(menu: Int, item: Int)
    }

    enum MenuAction: String {
        case sendAgain = "Send Again"
        case send = "Send"
    }

    struct MenuEntry {
        var title: String
        var commandCharacter: String?
        var modifiers: Int?
        /// What a press does; nil for an item that does nothing here.
        var action: MenuAction?
        var disabled = false
    }

    struct Menu {
        var title: String
        var items: [MenuEntry]
    }

    /// Live (macOS 27, English Mail): Send Again is "D" with modifiers 1,
    /// and Start Dictation "D" with modifiers 24.
    static let englishMenus = [
        Menu(title: "Mail", items: []),
        Menu(title: "Edit", items: [MenuEntry(title: "Start Dictation", commandCharacter: "D", modifiers: 24)]),
        Menu(title: "Message", items: [
            MenuEntry(title: "Send", commandCharacter: "D", modifiers: 1, action: .send),
            MenuEntry(title: "Send Again", commandCharacter: "D", modifiers: 1, action: .sendAgain),
        ]),
    ]

    static let germanMenus = [
        Menu(title: "Mail", items: []),
        Menu(title: "Bearbeiten", items: [MenuEntry(title: "Diktat starten", commandCharacter: "D", modifiers: 24)]),
        Menu(title: "Nachricht", items: [
            MenuEntry(title: "Senden", commandCharacter: "D", modifiers: 1, action: .send),
            MenuEntry(title: "Erneut senden", commandCharacter: "D", modifiers: 1, action: .sendAgain),
        ]),
    ]

    /// `menus` with every shortcut removed.
    static func withoutShortcuts(_ menus: [Menu]) -> [Menu] {
        menus.map { menu in
            Menu(title: menu.title, items: menu.items.map {
                MenuEntry(title: $0.title, action: $0.action, disabled: $0.disabled)
            })
        }
    }

    enum Kind {
        case mailViewer
        case viewer
        case compose
        case panel
    }

    struct Window {
        let id: Int
        let kind: Kind
        var title = ""
        var sheets = 0
        var standard = true
    }

    struct Press: Equatable {
        let item: String
        let keyWindow: Int?
    }

    // MARK: Behaviour

    var mailRunning = true
    var axAnswers = true
    /// The title Mail gives the eml's viewer and the compose made from it.
    var messageTitle = "Test Subject"
    var viewerAppears = true
    var viewerDelay: TimeInterval = 0.3
    /// Another standard window appears together with the viewer.
    var strayWindowWithViewer = false
    /// A viewer for another message, with this title, appears alone where
    /// the eml's viewer should; the eml's own viewer follows 2s later.
    var strayViewerInsteadOfViewer: String?
    /// A compose with this title, not made by Send Again, appears alone
    /// where ours should; ours follows 2s later.
    var strayComposeInsteadOfCompose: String?
    /// The compose first shows "New Message" and takes `messageTitle` this
    /// long after it appears.
    var composeTitleDelay: TimeInterval?
    /// A non-standard window (a panel) appears together with the viewer.
    var strayPanelWithViewer = false
    var composeAppears = true
    var composeDelay: TimeInterval = 0.3
    var composeArrivesWithSheet = false
    /// The compose closes this long after it appears, without being sent.
    var composeClosedByUserAfter: TimeInterval?
    var refusesFrontmost = false
    /// The key window stays this window whatever is raised.
    var focusStuckOn: Int?
    /// The main window stays this window whatever is raised.
    var mainStuckOn: Int?
    /// Raising the viewer turns it into a non-standard window.
    var viewerTurnsNonStandardWhenRaised = false
    /// This many Send presses on a compose are taken without effect.
    var sendIgnoredTimes = 0
    /// What every Send press returns, whether or not it acted.
    var sendPressResult: AXError = .success
    var sheetOnSend = false
    var sendNeverEnabled = false
    /// How long after an accepted Send the compose window closes.
    var sendCloseDelay: TimeInterval = 0.5
    var menus = englishMenus

    // MARK: State

    private(set) var time: TimeInterval = 0
    private(set) var windows: [Window] = [Window(id: 1, kind: .mailViewer)]
    private(set) var frontmost = false
    private(set) var focused: Int? = 1
    private(set) var main: Int? = 1
    private var scheduled: [(at: TimeInterval, action: () -> Void)] = []
    private var nextID = 100

    // MARK: Records

    private(set) var presses: [Press] = []
    private(set) var sentWindows: [Int] = []
    private(set) var closedByButton: [Int] = []
    private(set) var openedURLs: [URL] = []
    private(set) var launches = 0
    private(set) var axCalls = 0
    private(set) var viewerID: Int?
    private(set) var composeID: Int?
    private(set) var strayID: Int?

    /// A compose the user already had open when the binary ran.
    @discardableResult
    func addBystanderCompose() -> Int {
        let id = takeID()
        windows.append(Window(id: id, kind: .compose))
        return id
    }

    var sendPresses: [Press] { presses.filter { $0.item == "Send" } }
    var sendAgainPresses: [Press] { presses.filter { $0.item == "Send Again" } }

    func isOpen(_ id: Int?) -> Bool {
        guard let id else { return false }
        return windows.contains { $0.id == id }
    }

    // MARK: Clock

    var now: TimeInterval { time }

    func sleep(_ seconds: TimeInterval) {
        let end = time + max(seconds, 0.001)
        while let next = scheduled.enumerated().filter({ $0.element.at <= end }).min(by: { $0.element.at < $1.element.at }) {
            scheduled.remove(at: next.offset)
            time = max(time, next.element.at)
            next.element.action()
        }
        time = end
    }

    private func after(_ delay: TimeInterval, _ action: @escaping () -> Void) {
        scheduled.append((time + delay, action))
    }

    private func takeID() -> Int {
        nextID += 1
        return nextID
    }

    // MARK: MailWorkspace

    func runningMailPID() -> Int32? {
        mailRunning ? 4242 : nil
    }

    func launchMail(timeout: TimeInterval) throws {
        launches += 1
        after(0.5) { self.mailRunning = true }
    }

    func open(_ url: URL, timeout: TimeInterval) throws {
        openedURLs.append(url)
        if !refusesFrontmost { frontmost = true }
        guard viewerAppears else { return }
        if let strayTitle = strayViewerInsteadOfViewer {
            after(viewerDelay) { self.strayID = self.appendWindow(.viewer, title: strayTitle) }
        }
        after(viewerDelay + (strayViewerInsteadOfViewer == nil ? 0 : 2)) {
            let id = self.takeID()
            self.viewerID = id
            self.windows.append(Window(id: id, kind: .viewer, title: self.messageTitle))
            self.focusOn(id)
            if self.strayWindowWithViewer {
                self.windows.append(Window(id: self.takeID(), kind: .viewer))
            }
            if self.strayPanelWithViewer {
                self.windows.append(Window(id: self.takeID(), kind: .panel))
            }
        }
    }

    private func retitle(_ id: Int, _ title: String) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].title = title
    }

    private func appendWindow(_ kind: Kind, title: String) -> Int {
        let id = takeID()
        windows.append(Window(id: id, kind: kind, title: title))
        focusOn(id)
        return id
    }

    private func focusOn(_ id: Int) {
        main = mainStuckOn ?? id
        if focusStuckOn == nil { focused = id }
    }

    // MARK: AXClient

    func application(pid: Int32) -> UIElement {
        UIElement(Node.app)
    }

    private func window(_ id: Int) -> Window? {
        windows.first { $0.id == id }
    }

    func attribute(_ name: String, of element: UIElement) -> AXAttributeValue? {
        axCalls += 1
        guard let node = element.handle.base as? Node else { return nil }
        switch node {
        case .app:
            switch name {
            case kAXWindowsAttribute:
                return axAnswers ? .elements(windows.map { UIElement(Node.window($0.id)) }) : nil
            case kAXFrontmostAttribute: return .bool(frontmost)
            case kAXFocusedWindowAttribute: return focused.flatMap { isOpen($0) ? .element(UIElement(Node.window($0))) : nil }
            case kAXMainWindowAttribute: return main.flatMap { isOpen($0) ? .element(UIElement(Node.window($0))) : nil }
            case kAXMenuBarAttribute: return .element(UIElement(Node.menuBar))
            default: return nil
            }
        case let .window(id):
            guard let window = window(id) else { return nil }
            switch name {
            case kAXRoleAttribute: return .string(kAXWindowRole)
            case kAXSubroleAttribute: return .string(window.kind == .panel || !window.standard ? kAXFloatingWindowSubrole : kAXStandardWindowSubrole)
            case kAXChildrenAttribute: return .elements((0..<window.sheets).map { _ in UIElement(Node.sheet(id)) })
            case kAXCloseButtonAttribute: return .element(UIElement(Node.closeButton(id)))
            case kAXTitleAttribute: return .string(window.title)
            default: return nil
            }
        case .sheet:
            return name == kAXRoleAttribute ? .string(kAXSheetRole) : nil
        case .closeButton:
            return nil
        case .menuBar:
            return name == kAXChildrenAttribute ? .elements(menus.indices.map { UIElement(Node.menuBarItem($0)) }) : nil
        case let .menuBarItem(menu):
            switch name {
            case kAXTitleAttribute: return .string(menus[menu].title)
            case kAXChildrenAttribute: return .elements([UIElement(Node.menu(menu))])
            default: return nil
            }
        case let .menu(menu):
            guard name == kAXChildrenAttribute else { return nil }
            // With another app frontmost, Mail hides Message > Send Again.
            let visible = menus[menu].items.indices.filter { frontmost || menus[menu].items[$0].action == nil }
            return .elements(visible.map { UIElement(Node.menuItem(menu: menu, item: $0)) })
        case let .menuItem(menu, item):
            let entry = menus[menu].items[item]
            switch name {
            case kAXTitleAttribute: return .string(entry.title)
            case kAXEnabledAttribute: return .bool(isEnabled(entry))
            case kAXMenuItemCmdCharAttribute: return entry.commandCharacter.map { .string($0) }
            case kAXMenuItemCmdModifiersAttribute: return entry.commandCharacter == nil ? nil : .int(entry.modifiers ?? 0)
            default: return nil
            }
        }
    }

    private func isEnabled(_ entry: MenuEntry) -> Bool {
        guard !entry.disabled else { return false }
        guard let action = entry.action else { return true }
        guard let focused, let window = window(focused) else { return false }
        switch action {
        case .sendAgain: return window.kind == .viewer
        case .send: return !sendNeverEnabled && window.kind == .compose
        }
    }

    func setAttribute(_ name: String, of element: UIElement, to value: Bool) -> AXError {
        axCalls += 1
        guard let node = element.handle.base as? Node, value else { return .illegalArgument }
        switch (node, name) {
        case (.app, kAXFrontmostAttribute):
            if !refusesFrontmost { frontmost = true }
            return .success
        case (.window(let id), kAXMainAttribute):
            guard let index = windows.firstIndex(where: { $0.id == id }) else { return .invalidUIElement }
            if viewerTurnsNonStandardWhenRaised && windows[index].kind == .viewer {
                windows[index].standard = false
            }
            focusOn(id)
            return .success
        default:
            return .attributeUnsupported
        }
    }

    func performAction(_ action: String, on element: UIElement) -> AXError {
        axCalls += 1
        guard let node = element.handle.base as? Node else { return .illegalArgument }
        switch (node, action) {
        case (.window(let id), kAXRaiseAction):
            return isOpen(id) ? .success : .invalidUIElement
        case (.closeButton(let id), kAXPressAction):
            guard isOpen(id) else { return .invalidUIElement }
            closedByButton.append(id)
            windows.removeAll { $0.id == id }
            return .success
        case let (.menuItem(menu, item), kAXPressAction):
            return press(menus[menu].items[item])
        default:
            return .actionUnsupported
        }
    }

    /// Records the press under the action's English name, whatever the
    /// item's title, so a localized press counts as Send or Send Again.
    private func press(_ entry: MenuEntry) -> AXError {
        presses.append(Press(item: entry.action?.rawValue ?? entry.title, keyWindow: focused))
        guard frontmost, let focused, let target = window(focused), let action = entry.action else { return .success }
        switch (action, target.kind) {
        case (.sendAgain, .viewer):
            guard composeAppears else { return .success }
            if let strayTitle = strayComposeInsteadOfCompose {
                after(composeDelay) { self.strayID = self.appendWindow(.compose, title: strayTitle) }
            }
            after(composeDelay + (strayComposeInsteadOfCompose == nil ? 0 : 2)) {
                let id = self.takeID()
                self.composeID = id
                let title = self.composeTitleDelay == nil ? self.messageTitle : "New Message"
                self.windows.append(Window(id: id, kind: .compose, title: title, sheets: self.composeArrivesWithSheet ? 1 : 0))
                self.focusOn(id)
                if let titleDelay = self.composeTitleDelay {
                    self.after(titleDelay) { self.retitle(id, self.messageTitle) }
                }
                if let closeAfter = self.composeClosedByUserAfter {
                    self.after(closeAfter) { self.windows.removeAll { $0.id == id } }
                }
            }
            return .success
        case (_, .compose):
            return send(focused)
        default:
            return .success
        }
    }

    private func send(_ id: Int) -> AXError {
        if sheetOnSend {
            if let index = windows.firstIndex(where: { $0.id == id }) { windows[index].sheets += 1 }
        } else if sendIgnoredTimes > 0 {
            sendIgnoredTimes -= 1
        } else {
            sentWindows.append(id)
            after(sendCloseDelay) { self.windows.removeAll { $0.id == id } }
        }
        return sendPressResult
    }
}
