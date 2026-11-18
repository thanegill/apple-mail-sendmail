import ApplicationServices
import Foundation

/// The HTML path through Accessibility and Launch Services, with no Apple
/// Events: executes `HTMLPlan.steps`.
public struct AXHTMLDelivery: HTMLDelivery {
    let ax: AXClient
    let workspace: MailWorkspace
    let clock: Clock
    let accessibility: AccessibilityPermission
    let trace: (String) -> Void

    /// `trace` receives one line per notable decision, such as how a menu
    /// item was found; it must not write to the caller's stdout or stderr.
    public init(
        ax: AXClient, workspace: MailWorkspace, clock: Clock, accessibility: AccessibilityPermission,
        trace: @escaping (String) -> Void = { _ in }
    ) {
        self.ax = ax
        self.workspace = workspace
        self.clock = clock
        self.accessibility = accessibility
        self.trace = trace
    }

    public func deliverHTML(emlURL: URL, send: Bool) throws {
        try run(HTMLPlan.steps(emlPath: emlURL.path, send: send))
    }

    public func run(_ steps: [HTMLStep]) throws {
        let run = PlanRun(delivery: self)
        for step in steps {
            try run.execute(step)
        }
    }
}

private final class PlanRun {
    let ax: AXClient
    let workspace: MailWorkspace
    let clock: Clock
    let accessibility: AccessibilityPermission
    let trace: (String) -> Void
    var app: UIElement?
    var snapshots: [WindowSnapshot: [UIElement]] = [:]
    var windows: [HTMLWindow: UIElement] = [:]

    init(delivery: AXHTMLDelivery) {
        ax = delivery.ax
        workspace = delivery.workspace
        clock = delivery.clock
        accessibility = delivery.accessibility
        trace = delivery.trace
    }

    func execute(_ step: HTMLStep) throws {
        switch step {
        case .requireAccessibility:
            try accessibility.require()
        case let .launchMail(timeoutMs):
            try launchMail(timeout: seconds(timeoutMs))
        case let .snapshotWindows(snapshot, settle):
            snapshots[snapshot] = try settle ? settledWindows() : currentWindows()
        case let .openEml(path):
            try workspace.open(URL(fileURLWithPath: path), timeout: 15)
        case let .waitForNewWindow(window, since, timeoutMs):
            windows[window] = try waitForNewWindow(window, since: since, timeout: seconds(timeoutMs))
        case let .pressMenuItem(item, window, guardChecks, guardTimeoutMs):
            let target = try requireWindow(window)
            switch try guardedPress(item, on: target, window: window, checks: guardChecks, timeout: seconds(guardTimeoutMs)) {
            case .pressed:
                break
            case .targetGone:
                throw DeliveryError("The \(window.displayName) window closed before the \(item.fallbackName) press")
            }
        case let .pressUntilWindowCloses(item, window, guardChecks, guardTimeoutMs, maxPresses, readyTimeoutMs, goneTimeoutMs):
            try pressUntilClosed(
                item, window: window, checks: guardChecks, guardTimeout: seconds(guardTimeoutMs),
                maxPresses: maxPresses, readyTimeout: seconds(readyTimeoutMs), goneTimeout: seconds(goneTimeoutMs)
            )
        case let .closeWindow(window):
            closeWindow(try requireWindow(window))
        }
    }

    // MARK: - Polling

    func seconds(_ milliseconds: Int) -> TimeInterval {
        TimeInterval(milliseconds) / 1000
    }

    func poll<T>(timeout: TimeInterval, interval: TimeInterval = 0.1, _ body: () throws -> T?) rethrows -> T? {
        try clock.poll(timeout: timeout, interval: interval, body)
    }

    // MARK: - Mail and its windows

    func requireApp() throws -> UIElement {
        guard let app else { throw DeliveryError("internal error: Mail's application element was used before launch_mail") }
        return app
    }

    func requireWindow(_ window: HTMLWindow) throws -> UIElement {
        guard let element = windows[window] else {
            throw DeliveryError("internal error: the \(window.displayName) window was used before it was found")
        }
        return element
    }

    func launchMail(timeout: TimeInterval) throws {
        let pid = try workspace.ensureMailRunning(clock: clock, timeout: timeout)
        let app = ax.application(pid: pid)
        self.app = app
        let answered = poll(timeout: timeout) { readWindows(app) }
        if answered == nil {
            throw DeliveryError("Mail's accessibility interface did not answer within \(Int(timeout))s")
        }
    }

    func readWindows(_ app: UIElement) -> [UIElement]? {
        guard case let .elements(elements)? = ax.attribute(kAXWindowsAttribute, of: app) else { return nil }
        return elements
    }

    func currentWindows() throws -> [UIElement] {
        guard let windows = readWindows(try requireApp()) else {
            throw DeliveryError("Mail's window list could not be read")
        }
        return windows
    }

    /// Waits up to 5s for the window list to stay the same for 0.6s.
    func settledWindows() throws -> [UIElement] {
        let quiet: TimeInterval = 0.6
        let deadline = clock.now + 5
        var last = try currentWindows()
        var stableSince = clock.now
        while clock.now < deadline {
            clock.sleep(0.1)
            let current = try currentWindows()
            if current != last {
                last = current
                stableSince = clock.now
            } else if clock.now - stableSince >= quiet {
                break
            }
        }
        return last
    }

    func isStandardWindow(_ window: UIElement) -> Bool {
        ax.attribute(kAXSubroleAttribute, of: window) == .string(kAXStandardWindowSubrole)
    }

    /// An unreadable window list counts as present, so a read failure can
    /// never pass for a compose that closed because Mail sent it.
    func isPresent(_ window: UIElement) -> Bool {
        guard let app, let windows = readWindows(app) else { return true }
        return windows.contains(window)
    }

    func hasSheet(_ window: UIElement) -> Bool {
        guard case let .elements(children)? = ax.attribute(kAXChildrenAttribute, of: window) else { return false }
        return children.contains { ax.attribute(kAXRoleAttribute, of: $0) == .string(kAXSheetRole) }
    }

    func waitForNewWindow(_ window: HTMLWindow, since snapshot: WindowSnapshot, timeout: TimeInterval) throws -> UIElement {
        guard let before = snapshots[snapshot] else {
            throw DeliveryError("internal error: no \(snapshot.rawValue) window snapshot")
        }
        let app = try requireApp()
        let added = poll(timeout: timeout) { () -> [UIElement]? in
            let new = (readWindows(app) ?? []).filter { !before.contains($0) && isStandardWindow($0) }
            return new.isEmpty ? nil : new
        }
        guard let added else {
            switch window {
            case .viewer: throw DeliveryError("Mail did not open a viewer for the eml within \(Int(timeout))s")
            case .compose: throw DeliveryError("Compose window did not appear after Send Again within \(Int(timeout))s")
            }
        }
        guard added.count == 1 else {
            throw DeliveryError("Mail opened more than one new window while waiting for the \(window.displayName); refusing to guess which is ours (found \(added.count))")
        }
        return added[0]
    }

    // MARK: - Menus

    func children(_ element: UIElement) -> [UIElement] {
        guard case let .elements(children)? = ax.attribute(kAXChildrenAttribute, of: element) else { return [] }
        return children
    }

    func title(_ element: UIElement) -> String? {
        guard case let .string(title)? = ax.attribute(kAXTitleAttribute, of: element) else { return nil }
        return title
    }

    /// Each top-level menu-bar item's title and the items of its menu, read
    /// afresh on every call.
    func topLevelMenus() -> [(title: String?, items: [UIElement])] {
        guard let app, case let .element(menuBar)? = ax.attribute(kAXMenuBarAttribute, of: app) else { return [] }
        return children(menuBar).map { barItem in
            (title(barItem), children(barItem).first.map(children) ?? [])
        }
    }

    func isEnabled(_ element: UIElement) -> Bool {
        ax.attribute(kAXEnabledAttribute, of: element) == .bool(true)
    }

    func hasShortcut(_ element: UIElement, of item: MenuItemTarget) -> Bool {
        ax.attribute(kAXMenuItemCmdCharAttribute, of: element) == .string(item.commandCharacter)
            && ax.attribute(kAXMenuItemCmdModifiersAttribute, of: element) == .int(item.modifiers)
    }

    enum FoundBy: Equatable {
        case shortcut
        case title
    }

    /// The menu item to press for `item`: the only enabled item with its
    /// shortcut in any top-level menu, else the item with its fallback title
    /// (enabled or not), else nil. Throws when several enabled items share
    /// the shortcut, since pressing any of them is a guess.
    func resolve(_ item: MenuItemTarget) throws -> (element: UIElement, foundBy: FoundBy)? {
        let menus = topLevelMenus()
        let byShortcut = menus.flatMap(\.items).filter { hasShortcut($0, of: item) && isEnabled($0) }
        if byShortcut.count > 1 {
            throw DeliveryError("Mail has \(byShortcut.count) enabled menu items with the \(item.shortcutName) shortcut; refusing to guess which one is \(item.fallbackName), and nothing was pressed")
        }
        if let only = byShortcut.first { return (only, .shortcut) }
        guard let menu = menus.first(where: { $0.title == item.fallbackMenu }),
              let element = menu.items.first(where: { title($0) == item.fallbackTitle })
        else { return nil }
        return (element, .title)
    }

    // MARK: - Guarded press

    enum PressOutcome {
        case pressed(AXError)
        case targetGone
    }

    func raise(_ target: UIElement) throws {
        _ = ax.setAttribute(kAXMainAttribute, of: target, to: true)
        _ = ax.performAction(kAXRaiseAction, on: target)
        _ = ax.setAttribute(kAXFrontmostAttribute, of: try requireApp(), to: true)
    }

    /// nil when every check holds for `target`.
    func failedCheck(_ check: GuardCheck, target: UIElement, window: HTMLWindow) throws -> String? {
        let app = try requireApp()
        switch check {
        case .frontmost:
            return ax.attribute(kAXFrontmostAttribute, of: app) == .bool(true) ? nil : "Mail is not the frontmost app"
        case .focusedWindow:
            return ax.attribute(kAXFocusedWindowAttribute, of: app) == .element(target)
                ? nil : "the key window (AXFocusedWindow) is not the \(window.displayName) window"
        case .mainWindow:
            return ax.attribute(kAXMainWindowAttribute, of: app) == .element(target)
                ? nil : "the main window (AXMainWindow) is not the \(window.displayName) window"
        case .standardWindow:
            return isStandardWindow(target) ? nil : "the \(window.displayName) window is not an AXStandardWindow"
        case .noSheet:
            return hasSheet(target) ? "the \(window.displayName) window has a sheet open" : nil
        }
    }

    /// Raises `target` and re-runs every check until all hold, then looks the
    /// menu item up again and presses it once. Never presses unverified; on
    /// timeout it throws naming the last failed check.
    func guardedPress(
        _ item: MenuItemTarget, on target: UIElement, window: HTMLWindow,
        checks: [GuardCheck], timeout: TimeInterval
    ) throws -> PressOutcome {
        let deadline = clock.now + timeout
        var lastFailure = "no check ran"
        repeat {
            try raise(target)
            clock.sleep(0.15)
            guard isPresent(target) else { return .targetGone }
            var failure: String?
            for check in checks {
                failure = try failedCheck(check, target: target, window: window)
                if failure != nil { break }
            }
            if failure == nil {
                if let resolved = try resolve(item) {
                    if isEnabled(resolved.element) {
                        trace(pressTrace(item, foundBy: resolved.foundBy, window: window))
                        return .pressed(ax.performAction(kAXPressAction, on: resolved.element))
                    }
                    failure = "Mail's \(item.fallbackName) menu item is disabled"
                } else {
                    failure = "no enabled menu item has the \(item.shortcutName) shortcut, and Mail's \(item.fallbackName) menu item was not found by title"
                }
            }
            lastFailure = failure ?? lastFailure
        } while clock.now < deadline
        throw DeliveryError("The \(window.displayName) window did not pass the key-window check within \(Int(timeout))s; the \(item.fallbackName) press was not sent. Last failed check: \(lastFailure)")
    }

    func pressTrace(_ item: MenuItemTarget, foundBy: FoundBy, window: HTMLWindow) -> String {
        switch foundBy {
        case .shortcut:
            return "pressing \(item.fallbackName) on the \(window.displayName) window, found by its \(item.shortcutName) shortcut"
        case .title:
            return "pressing \(item.fallbackName) on the \(window.displayName) window, found by its English title (no enabled item has the \(item.shortcutName) shortcut)"
        }
    }

    /// Mail closes the compose when it accepts Send, so a compose still open
    /// after the gone-poll means the press was not taken and pressing again
    /// cannot send twice. An AXPress can report kAXErrorCannotComplete even
    /// when it acted, so the press result never decides a retry.
    func pressUntilClosed(
        _ item: MenuItemTarget, window: HTMLWindow, checks: [GuardCheck], guardTimeout: TimeInterval,
        maxPresses: Int, readyTimeout: TimeInterval, goneTimeout: TimeInterval
    ) throws {
        let target = try requireWindow(window)
        var presses = 0
        var lastPress = AXError.success
        while presses < maxPresses {
            guard isPresent(target) else {
                if presses > 0 { return }
                throw DeliveryError("The \(window.displayName) window closed before the \(item.fallbackName) press")
            }
            let ready = try poll(timeout: readyTimeout, interval: 0.2) { () -> Bool? in
                guard let resolved = try resolve(item), isEnabled(resolved.element) else { return nil }
                return true
            }
            if ready == nil {
                if presses > 0 && !isPresent(target) { return }
                throw DeliveryError("Mail's \(item.fallbackName) menu item (\(item.shortcutName)) did not become available within \(Int(readyTimeout))s; the \(window.displayName) was not sent")
            }
            switch try guardedPress(item, on: target, window: window, checks: checks, timeout: guardTimeout) {
            case .targetGone:
                if presses > 0 { return }
                throw DeliveryError("The \(window.displayName) window closed before the \(item.fallbackName) press")
            case let .pressed(result):
                presses += 1
                lastPress = result
            }
            let gone = poll(timeout: goneTimeout) { isPresent(target) ? nil : true }
            if gone != nil { return }
            if hasSheet(target) {
                throw DeliveryError("A sheet is open on the \(window.displayName) window after the \(item.fallbackName) press; not pressing \(item.fallbackTitle) through it, and the message was not sent")
            }
        }
        throw DeliveryError("\(item.fallbackTitle) did not complete: the \(window.displayName) window is still open after \(maxPresses) \(item.fallbackName) presses (the last press returned AX error \(lastPress.rawValue))")
    }

    // MARK: - Closing

    /// Presses the window's close button and waits up to 2s for it to go.
    /// Best effort: by now the message is in its compose or sent, so a
    /// viewer left open must not fail the run.
    func closeWindow(_ target: UIElement) {
        guard case let .element(closeButton)? = ax.attribute(kAXCloseButtonAttribute, of: target) else { return }
        _ = ax.performAction(kAXPressAction, on: closeButton)
        _ = poll(timeout: 2) { isPresent(target) ? nil : true }
    }
}
