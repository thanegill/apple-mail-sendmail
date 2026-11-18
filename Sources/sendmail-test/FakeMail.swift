import ApplicationServices
import Foundation
import SendmailCore

/// A state machine standing in for Mail, its Accessibility tree, Launch
/// Services and the clock, so `AXHTMLDelivery` runs without a real Mail.
///
/// Like Mail, a menu press acts on the key (focused) window, and only while
/// Mail is frontmost: Send Again on a viewer opens a compose; Send Again or
/// Send on a compose sends it. Time advances only when the code under test
/// sleeps.
final class FakeMail: AXClient, MailWorkspace, Clock {
    enum Node: Hashable {
        case app
        case window(Int)
        case closeButton(Int)
        case sheet(Int)
        case menuBar
        case menuBarItem(String)
        case menu(String)
        case menuItem(menu: String, item: String)
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
    var viewerAppears = true
    var viewerDelay: TimeInterval = 0.3
    /// Another standard window appears together with the viewer.
    var strayWindowWithViewer = false
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
        after(viewerDelay) {
            let id = self.takeID()
            self.viewerID = id
            self.windows.append(Window(id: id, kind: .viewer))
            self.focusOn(id)
            if self.strayWindowWithViewer {
                self.windows.append(Window(id: self.takeID(), kind: .viewer))
            }
            if self.strayPanelWithViewer {
                self.windows.append(Window(id: self.takeID(), kind: .panel))
            }
        }
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
            default: return nil
            }
        case .sheet:
            return name == kAXRoleAttribute ? .string(kAXSheetRole) : nil
        case .closeButton:
            return nil
        case .menuBar:
            return name == kAXChildrenAttribute ? .elements(["Mail", "Message"].map { UIElement(Node.menuBarItem($0)) }) : nil
        case let .menuBarItem(title):
            switch name {
            case kAXTitleAttribute: return .string(title)
            case kAXChildrenAttribute: return .elements([UIElement(Node.menu(title))])
            default: return nil
            }
        case let .menu(title):
            guard name == kAXChildrenAttribute else { return nil }
            // With another app frontmost, Mail hides Message > Send Again.
            guard title == "Message", frontmost else { return .elements([]) }
            return .elements(["Send", "Send Again"].map { UIElement(Node.menuItem(menu: title, item: $0)) })
        case let .menuItem(_, item):
            switch name {
            case kAXTitleAttribute: return .string(item)
            case kAXEnabledAttribute: return .bool(isEnabled(item))
            default: return nil
            }
        }
    }

    private func isEnabled(_ item: String) -> Bool {
        guard item == "Send" else { return true }
        guard !sendNeverEnabled, let focused, let window = window(focused) else { return false }
        return window.kind == .compose
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
        case (.menuItem(_, let item), kAXPressAction):
            return press(item)
        default:
            return .actionUnsupported
        }
    }

    private func press(_ item: String) -> AXError {
        presses.append(Press(item: item, keyWindow: focused))
        guard frontmost, let focused, let target = window(focused) else { return .success }
        switch (item, target.kind) {
        case ("Send Again", .viewer):
            guard composeAppears else { return .success }
            after(composeDelay) {
                let id = self.takeID()
                self.composeID = id
                self.windows.append(Window(id: id, kind: .compose, sheets: self.composeArrivesWithSheet ? 1 : 0))
                self.focusOn(id)
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
