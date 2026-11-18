import ApplicationServices
import Foundation

/// Sends no Apple Events, so the .eml path needs Accessibility but no
/// Automation grant.
public struct AXEmlDelivery: EmlDelivery {
    let ax: AXClient
    let workspace: MailWorkspace
    let clock: Clock
    let accessibility: AccessibilityPermission
    let trace: (String) -> Void

    /// `trace` must not write to the caller's stdout or stderr, where cron
    /// would mail it.
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

    public func deliverEml(emlURL: URL, subject: String, send: Bool) throws {
        try run(EmlPlan.steps(emlPath: emlURL.path, send: send), subject: subject)
    }

    public func run(_ steps: [EmlStep], subject: String) throws {
        let run = PlanRun(delivery: self, subject: subject)
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
    let subject: String
    var app: UIElement?
    var snapshots: [WindowSnapshot: [UIElement]] = [:]
    var windows: [EmlWindow: UIElement] = [:]

    init(delivery: AXEmlDelivery, subject: String) {
        ax = delivery.ax
        workspace = delivery.workspace
        clock = delivery.clock
        accessibility = delivery.accessibility
        trace = delivery.trace
        self.subject = subject
    }

    func execute(_ step: EmlStep) throws {
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
        case let .pressMenuItem(item, window, guardChecks, verify, guardTimeoutMs):
            let target = try requireWindow(window)
            switch try guardedPress(item, on: target, window: window, checks: guardChecks, verify: verify, timeout: seconds(guardTimeoutMs)) {
            case .pressed:
                break
            case .targetGone:
                throw DeliveryError("The \(window.displayName) window closed before the \(item.fallbackName) press")
            }
        case let .pressUntilWindowCloses(item, window, guardChecks, verify, guardTimeoutMs, maxPresses, readyTimeoutMs, goneTimeoutMs):
            try pressUntilClosed(
                item, window: window, checks: guardChecks, verify: verify, guardTimeout: seconds(guardTimeoutMs),
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

    func requireWindow(_ window: EmlWindow) throws -> UIElement {
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

    func waitForNewWindow(_ window: EmlWindow, since snapshot: WindowSnapshot, timeout: TimeInterval) throws -> UIElement {
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

    /// Read afresh on every call, never cached: Mail's menus change with its
    /// key window.
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

    /// Throws when several enabled items share the shortcut: pressing any of
    /// them is a guess.
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

    func failedCheck(_ check: GuardCheck, target: UIElement, window: EmlWindow) throws -> String? {
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

    enum ContentCheckResult {
        case passed(trace: String?)
        case failed(String)
    }

    func contentCheck(_ check: WindowCheck, target: UIElement, window: EmlWindow) -> ContentCheckResult {
        switch check {
        case .titleMatchesSubject:
            let expected = WindowCheck.normalizedTitle(subject)
            guard !expected.isEmpty else { return .passed(trace: nil) }
            let shown = title(target)
            if let shown, WindowCheck.normalizedTitle(shown) == expected {
                return .passed(trace: "the \(window.displayName) window's title (AXTitle) \(String(reflecting: shown)) matches the Subject")
            }
            return .failed("the \(window.displayName) window's title (AXTitle) is \(shown.map { String(reflecting: $0) } ?? "unreadable"), but the message's Subject is \(String(reflecting: subject))")
        }
    }

    /// Never presses unverified: the item is looked up afresh after every
    /// check holds, and a timeout throws without pressing.
    func guardedPress(
        _ item: MenuItemTarget, on target: UIElement, window: EmlWindow,
        checks: [GuardCheck], verify: [WindowCheck], timeout: TimeInterval
    ) throws -> PressOutcome {
        if verify.contains(.titleMatchesSubject) && WindowCheck.normalizedTitle(subject).isEmpty {
            trace("the message has no Subject, so Mail titles the \(window.displayName) window with a localized placeholder; its title is not checked, and the window diff alone identifies it")
        }
        let deadline = clock.now + timeout
        var lastFailure = "no check ran"
        var lastFailureIsContents = false
        repeat {
            try raise(target)
            clock.sleep(0.15)
            guard isPresent(target) else { return .targetGone }
            var failure: String?
            for check in checks {
                failure = try failedCheck(check, target: target, window: window)
                if failure != nil { break }
            }
            lastFailureIsContents = false
            var verifiedTraces: [String] = []
            if failure == nil {
                for check in verify {
                    switch contentCheck(check, target: target, window: window) {
                    case let .passed(verifiedTrace):
                        if let verifiedTrace { verifiedTraces.append(verifiedTrace) }
                    case let .failed(reason):
                        failure = reason
                    }
                    if failure != nil { break }
                }
                lastFailureIsContents = failure != nil
            }
            if failure == nil {
                if let resolved = try resolve(item) {
                    if isEnabled(resolved.element) {
                        verifiedTraces.forEach(trace)
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
        if lastFailureIsContents {
            throw DeliveryError("The \(window.displayName) window does not show this message, so it may be a stray window and not ours; the \(item.fallbackName) press was not sent: \(lastFailure)")
        }
        throw DeliveryError("The \(window.displayName) window did not pass the key-window check within \(Int(timeout))s; the \(item.fallbackName) press was not sent. Last failed check: \(lastFailure)")
    }

    func pressTrace(_ item: MenuItemTarget, foundBy: FoundBy, window: EmlWindow) -> String {
        switch foundBy {
        case .shortcut:
            return "pressing \(item.fallbackName) on the \(window.displayName) window, found by its \(item.shortcutName) shortcut"
        case .title:
            return "pressing \(item.fallbackName) on the \(window.displayName) window, found by its English title (no enabled item has the \(item.shortcutName) shortcut)"
        }
    }

    /// Retrying is safe only because Mail closes the compose when it accepts
    /// Send: a compose still open means the press was not taken. AXPress can
    /// return kAXErrorCannotComplete (-25204) even when it acted, so the
    /// press result never decides a retry. Never press through a sheet.
    func pressUntilClosed(
        _ item: MenuItemTarget, window: EmlWindow, checks: [GuardCheck], verify: [WindowCheck], guardTimeout: TimeInterval,
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
            switch try guardedPress(item, on: target, window: window, checks: checks, verify: verify, timeout: guardTimeout) {
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
                // Backstop only: MailDriver.requireDeliverable refuses --send
                // without a Subject before Mail is touched.
                if WindowCheck.normalizedTitle(subject).isEmpty {
                    throw DeliveryError("Mail is asking to confirm sending a message with no Subject (a sheet opened on the \(window.displayName) window after the \(item.fallbackName) press); it is not confirmed, and the message was not sent. --send needs a Subject: add a non-empty Subject header, or leave out --send to get a draft")
                }
                throw DeliveryError("A sheet is open on the \(window.displayName) window after the \(item.fallbackName) press; not pressing \(item.fallbackTitle) through it, and the message was not sent")
            }
        }
        throw DeliveryError("\(item.fallbackTitle) did not complete: the \(window.displayName) window is still open after \(maxPresses) \(item.fallbackName) presses (the last press returned AX error \(lastPress.rawValue))")
    }

    // MARK: - Closing

    /// Best effort: by now the message is in its compose or sent, so a
    /// viewer left open must not fail the run.
    func closeWindow(_ target: UIElement) {
        guard case let .element(closeButton)? = ax.attribute(kAXCloseButtonAttribute, of: target) else { return }
        _ = ax.performAction(kAXPressAction, on: closeButton)
        _ = poll(timeout: 2) { isPresent(target) ? nil : true }
    }
}
