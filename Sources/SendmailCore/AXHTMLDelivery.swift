import ApplicationServices
import Foundation

/// The HTML path through Accessibility and Launch Services, with no Apple
/// Events: executes `HTMLPlan.steps`.
public struct AXHTMLDelivery: HTMLDelivery {
    let ax: AXClient
    let workspace: MailWorkspace
    let clock: Clock
    let accessibility: AccessibilityPermission

    public init(ax: AXClient, workspace: MailWorkspace, clock: Clock, accessibility: AccessibilityPermission) {
        self.ax = ax
        self.workspace = workspace
        self.clock = clock
        self.accessibility = accessibility
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
    var app: UIElement?
    var snapshots: [WindowSnapshot: [UIElement]] = [:]
    var windows: [HTMLWindow: UIElement] = [:]

    init(delivery: AXHTMLDelivery) {
        ax = delivery.ax
        workspace = delivery.workspace
        clock = delivery.clock
        accessibility = delivery.accessibility
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
        case let .pressMenuItem(menu, item, window, guardChecks, guardTimeoutMs):
            let target = try requireWindow(window)
            switch try guardedPress(menu: menu, item: item, on: target, window: window, checks: guardChecks, timeout: seconds(guardTimeoutMs)) {
            case .pressed:
                break
            case .targetGone:
                throw HTMLDeliveryError("The \(window.displayName) window closed before the \(menu) > \(item) press")
            }
        case let .pressUntilWindowCloses(menu, item, window, guardChecks, guardTimeoutMs, maxPresses, readyTimeoutMs, goneTimeoutMs):
            try pressUntilClosed(
                menu: menu, item: item, window: window, checks: guardChecks, guardTimeout: seconds(guardTimeoutMs),
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

    /// Calls `body` until it returns non-nil or `timeout` passes; checks at
    /// least once, and once more at the deadline.
    func poll<T>(timeout: TimeInterval, interval: TimeInterval = 0.1, _ body: () throws -> T?) rethrows -> T? {
        let deadline = clock.now + timeout
        while true {
            if let value = try body() { return value }
            if clock.now >= deadline { return nil }
            clock.sleep(min(interval, max(deadline - clock.now, 0.001)))
        }
    }

    // MARK: - Mail and its windows

    func requireApp() throws -> UIElement {
        guard let app else { throw HTMLDeliveryError("internal error: Mail's application element was used before launch_mail") }
        return app
    }

    func requireWindow(_ window: HTMLWindow) throws -> UIElement {
        guard let element = windows[window] else {
            throw HTMLDeliveryError("internal error: the \(window.displayName) window was used before it was found")
        }
        return element
    }

    func launchMail(timeout: TimeInterval) throws {
        var pid = workspace.runningMailPID()
        if pid == nil {
            try workspace.launchMail(timeout: timeout)
            pid = poll(timeout: timeout) { workspace.runningMailPID() }
        }
        guard let pid else { throw HTMLDeliveryError("Mail did not start within \(Int(timeout))s") }
        let app = ax.application(pid: pid)
        self.app = app
        let answered = poll(timeout: timeout) { readWindows(app) }
        if answered == nil {
            throw HTMLDeliveryError("Mail's accessibility interface did not answer within \(Int(timeout))s")
        }
    }

    func readWindows(_ app: UIElement) -> [UIElement]? {
        guard case let .elements(elements)? = ax.attribute(kAXWindowsAttribute, of: app) else { return nil }
        return elements
    }

    func currentWindows() throws -> [UIElement] {
        guard let windows = readWindows(try requireApp()) else {
            throw HTMLDeliveryError("Mail's window list could not be read")
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
            throw HTMLDeliveryError("internal error: no \(snapshot.rawValue) window snapshot")
        }
        let app = try requireApp()
        let added = poll(timeout: timeout) { () -> [UIElement]? in
            let new = (readWindows(app) ?? []).filter { !before.contains($0) && isStandardWindow($0) }
            return new.isEmpty ? nil : new
        }
        guard let added else {
            switch window {
            case .viewer: throw HTMLDeliveryError("Mail did not open a viewer for the eml within \(Int(timeout))s")
            case .compose: throw HTMLDeliveryError("Compose window did not appear after Send Again within \(Int(timeout))s")
            }
        }
        guard added.count == 1 else {
            throw HTMLDeliveryError("Mail opened more than one new window while waiting for the \(window.displayName); refusing to guess which is ours (found \(added.count))")
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

    /// Looked up afresh on every call: menu bar item `menu`, its menu, then
    /// the item titled `item`.
    func menuItem(menu: String, item: String) -> UIElement? {
        guard let app,
              case let .element(menuBar)? = ax.attribute(kAXMenuBarAttribute, of: app),
              let barItem = children(menuBar).first(where: { title($0) == menu }),
              let menuElement = children(barItem).first
        else { return nil }
        return children(menuElement).first { title($0) == item }
    }

    func isEnabled(_ element: UIElement) -> Bool {
        ax.attribute(kAXEnabledAttribute, of: element) == .bool(true)
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
        menu: String, item: String, on target: UIElement, window: HTMLWindow,
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
                if let menuItem = menuItem(menu: menu, item: item) {
                    if isEnabled(menuItem) {
                        return .pressed(ax.performAction(kAXPressAction, on: menuItem))
                    }
                    failure = "Mail's \(menu) > \(item) menu item is disabled"
                } else {
                    failure = "Mail's \(menu) > \(item) menu item was not found"
                }
            }
            lastFailure = failure ?? lastFailure
        } while clock.now < deadline
        throw HTMLDeliveryError("The \(window.displayName) window did not pass the key-window check within \(Int(timeout))s; the \(menu) > \(item) press was not sent. Last failed check: \(lastFailure)")
    }

    /// Mail closes the compose when it accepts Send, so a compose still open
    /// after the gone-poll means the press was not taken and pressing again
    /// cannot send twice. An AXPress can report kAXErrorCannotComplete even
    /// when it acted, so the press result never decides a retry.
    func pressUntilClosed(
        menu: String, item: String, window: HTMLWindow, checks: [GuardCheck], guardTimeout: TimeInterval,
        maxPresses: Int, readyTimeout: TimeInterval, goneTimeout: TimeInterval
    ) throws {
        let target = try requireWindow(window)
        var presses = 0
        var lastPress = AXError.success
        while presses < maxPresses {
            guard isPresent(target) else {
                if presses > 0 { return }
                throw HTMLDeliveryError("The \(window.displayName) window closed before the \(menu) > \(item) press")
            }
            let ready = poll(timeout: readyTimeout, interval: 0.2) { () -> Bool? in
                guard let menuItem = menuItem(menu: menu, item: item), isEnabled(menuItem) else { return nil }
                return true
            }
            if ready == nil {
                if presses > 0 && !isPresent(target) { return }
                throw HTMLDeliveryError("Mail's \(menu) > \(item) menu item did not become available within \(Int(readyTimeout))s; the \(window.displayName) was not sent")
            }
            switch try guardedPress(menu: menu, item: item, on: target, window: window, checks: checks, timeout: guardTimeout) {
            case .targetGone:
                if presses > 0 { return }
                throw HTMLDeliveryError("The \(window.displayName) window closed before the \(menu) > \(item) press")
            case let .pressed(result):
                presses += 1
                lastPress = result
            }
            let gone = poll(timeout: goneTimeout) { isPresent(target) ? nil : true }
            if gone != nil { return }
            if hasSheet(target) {
                throw HTMLDeliveryError("A sheet is open on the \(window.displayName) window after the \(menu) > \(item) press; not pressing \(item) through it, and the message was not sent")
            }
        }
        throw HTMLDeliveryError("\(item) did not complete: the \(window.displayName) window is still open after \(maxPresses) \(menu) > \(item) presses (the last press returned AX error \(lastPress.rawValue))")
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
