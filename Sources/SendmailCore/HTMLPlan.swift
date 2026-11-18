import Foundation

/// The windows the HTML path works on, found by window diff.
public enum HTMLWindow: String {
    case viewer
    case compose

    var displayName: String {
        switch self {
        case .viewer: return "eml viewer"
        case .compose: return "compose"
        }
    }
}

public enum WindowSnapshot: String {
    case beforeOpen = "before_open"
    case beforeCompose = "before_compose"
}

/// One check of the key-window guard that runs before every menu press.
/// Mail's menu commands act on its key window, so Send on the user's own
/// draft would send it.
public enum GuardCheck: String, CaseIterable {
    /// Menu items are hidden, and a press does nothing, unless Mail is frontmost.
    case frontmost
    case focusedWindow = "focused_window"
    case mainWindow = "main_window"
    case standardWindow = "standard_window"
    case noSheet = "no_sheet"
}

/// One step of the HTML path. `HTMLPlan.steps` builds the list, the AX
/// driver executes it, and the dry run prints it, so the printed plan is
/// what a live run does.
public enum HTMLStep: Equatable {
    case requireAccessibility
    /// Start Mail without activating it if it is not running, then wait for
    /// its accessibility interface to answer.
    case launchMail(timeoutMs: Int)
    /// Record Mail's windows. With `settle`, first wait for the list to stop
    /// changing, so session-restored windows count as "before".
    case snapshotWindows(WindowSnapshot, settle: Bool)
    /// Open the file in Mail through Launch Services, activating Mail.
    case openEml(path: String)
    /// Wait for exactly one new standard window since the snapshot. Two or
    /// more at once fail closed.
    case waitForNewWindow(HTMLWindow, since: WindowSnapshot, timeoutMs: Int)
    /// Raise the window, run the guard until it passes or times out, then
    /// press the menu item once. Never retried.
    case pressMenuItem(menu: String, item: String, window: HTMLWindow, guardChecks: [GuardCheck], guardTimeoutMs: Int)
    /// Press the menu item up to `maxPresses` times, each after waiting for
    /// it to be enabled and running the guard, until the window closes.
    /// Whether to press again is decided only by whether the window is
    /// still open with no sheet, never by what the press returned.
    case pressUntilWindowCloses(
        menu: String, item: String, window: HTMLWindow, guardChecks: [GuardCheck], guardTimeoutMs: Int,
        maxPresses: Int, readyTimeoutMs: Int, goneTimeoutMs: Int
    )
    case closeWindow(HTMLWindow)
}

public enum HTMLPlan {
    public static let maxSendPresses = 3

    public static func steps(emlPath: String, send: Bool) -> [HTMLStep] {
        let guardChecks = GuardCheck.allCases
        var steps: [HTMLStep] = [
            .requireAccessibility,
            .launchMail(timeoutMs: 10_000),
            .snapshotWindows(.beforeOpen, settle: true),
            .openEml(path: emlPath),
            .waitForNewWindow(.viewer, since: .beforeOpen, timeoutMs: 5_000),
            .snapshotWindows(.beforeCompose, settle: false),
            .pressMenuItem(menu: "Message", item: "Send Again", window: .viewer, guardChecks: guardChecks, guardTimeoutMs: 3_000),
            .waitForNewWindow(.compose, since: .beforeCompose, timeoutMs: 5_000),
        ]
        if send {
            steps.append(.pressUntilWindowCloses(
                menu: "Message", item: "Send", window: .compose, guardChecks: guardChecks, guardTimeoutMs: 3_000,
                maxPresses: maxSendPresses, readyTimeoutMs: 10_000, goneTimeoutMs: 3_000
            ))
        }
        steps.append(.closeWindow(.viewer))
        return steps
    }

    /// One JSON object per step (`planJSONLine`).
    public static func jsonLines(_ steps: [HTMLStep]) -> [String] {
        steps.map { planJSONLine(fields($0)) }
    }

    static func fields(_ step: HTMLStep) -> [String: Any] {
        switch step {
        case .requireAccessibility:
            return ["step": "require_accessibility"]
        case let .launchMail(timeoutMs):
            return ["step": "launch_mail", "activates": false, "timeout_ms": timeoutMs]
        case let .snapshotWindows(snapshot, settle):
            return ["step": "snapshot_windows", "snapshot": snapshot.rawValue, "settle": settle]
        case let .openEml(path):
            return ["step": "open_eml", "path": path, "activates": true]
        case let .waitForNewWindow(window, since, timeoutMs):
            return ["step": "wait_for_new_window", "window": window.rawValue, "since": since.rawValue, "timeout_ms": timeoutMs]
        case let .pressMenuItem(menu, item, window, guardChecks, guardTimeoutMs):
            return [
                "step": "press_menu_item", "menu": menu, "item": item, "window": window.rawValue,
                "guard": guardChecks.map(\.rawValue), "guard_timeout_ms": guardTimeoutMs,
            ]
        case let .pressUntilWindowCloses(menu, item, window, guardChecks, guardTimeoutMs, maxPresses, readyTimeoutMs, goneTimeoutMs):
            return [
                "step": "press_until_window_closes", "menu": menu, "item": item, "window": window.rawValue,
                "guard": guardChecks.map(\.rawValue), "guard_timeout_ms": guardTimeoutMs,
                "max_presses": maxPresses, "ready_timeout_ms": readyTimeoutMs, "gone_timeout_ms": goneTimeoutMs,
            ]
        case let .closeWindow(window):
            return ["step": "close_window", "window": window.rawValue]
        }
    }
}

/// One compact JSON object, keys sorted, slashes unescaped, so the e2e
/// harness can compare dry-run plans line by line with its templates.
func planJSONLine(_ fields: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

/// The dry run's HTML delivery: prints the plan, one JSON object per line,
/// and touches nothing else.
public struct HTMLPlanPrinter: HTMLDelivery {
    let output: (String) -> Void

    public init(output: @escaping (String) -> Void) {
        self.output = output
    }

    public func deliverHTML(emlURL: URL, send: Bool) throws {
        for line in HTMLPlan.jsonLines(HTMLPlan.steps(emlPath: emlURL.path, send: send)) {
            output(line)
        }
    }
}
