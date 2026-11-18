import Foundation

/// Found by window diff, never by title: a Subject can be empty, duplicated
/// or rewritten by Mail. The title only verifies the find (`WindowCheck`).
public enum EmlWindow: String {
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

/// Runs before every menu press. Mail's menu commands act on its key window,
/// and shift-cmd-D is Send on a compose, so a press with the user's own draft
/// key would send it.
public enum GuardCheck: String, CaseIterable {
    /// Menu items are hidden, and a press does nothing, unless Mail is frontmost.
    case frontmost
    case focusedWindow = "focused_window"
    case mainWindow = "main_window"
    case standardWindow = "standard_window"
    case noSheet = "no_sheet"
}

/// Found by shortcut, which Mail does not localize, else by English title.
public struct MenuItemTarget: Equatable {
    /// `kAXMenuItemCmdModifiers` is a bit set with Command implied: Shift
    /// adds 1, Option 2, Control 4, and 8 means no Command.
    public static let shiftModifier = 1

    public let commandCharacter: String
    public let modifiers: Int
    public let fallbackMenu: String
    public let fallbackTitle: String

    public init(commandCharacter: String, modifiers: Int, fallbackMenu: String, fallbackTitle: String) {
        self.commandCharacter = commandCharacter
        self.modifiers = modifiers
        self.fallbackMenu = fallbackMenu
        self.fallbackTitle = fallbackTitle
    }

    /// Live (macOS 27, English Mail): "D" / 1. Edit > Start Dictation is
    /// "D" / 24, which only the exact modifiers match rules out.
    public static let sendAgain = MenuItemTarget(commandCharacter: "D", modifiers: shiftModifier, fallbackMenu: "Message", fallbackTitle: "Send Again")
    /// Same shortcut on a compose; verified live with a German Mail.
    public static let send = MenuItemTarget(commandCharacter: "D", modifiers: shiftModifier, fallbackMenu: "Message", fallbackTitle: "Send")

    public var shortcutName: String {
        var parts: [String] = []
        if modifiers & 4 != 0 { parts.append("ctrl") }
        if modifiers & 2 != 0 { parts.append("opt") }
        if modifiers & 1 != 0 { parts.append("shift") }
        if modifiers & 8 == 0 { parts.append("cmd") }
        return (parts + [commandCharacter]).joined(separator: "-")
    }

    public var fallbackName: String { "\(fallbackMenu) > \(fallbackTitle)" }
}

/// Refuses a stray window that won the diff in place of ours.
public enum WindowCheck: String, CaseIterable {
    /// Mail titles both the viewer and the compose with the Subject (live,
    /// macOS 27). Skipped for an empty Subject: Mail then shows a localized
    /// placeholder title.
    case titleMatchesSubject = "title_matches_subject"

    public static func normalizedTitle(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The dry run prints the same steps a live run executes, and the e2e
/// templates pin them, so keep the plan the only input to `AXEmlDelivery`.
public enum EmlStep: Equatable {
    case requireAccessibility
    case launchMail(timeoutMs: Int)
    /// `settle` waits for the list to stop changing, so session-restored
    /// windows count as "before".
    case snapshotWindows(WindowSnapshot, settle: Bool)
    case openEml(path: String)
    /// Two or more new standard windows at once fail closed.
    case waitForNewWindow(EmlWindow, since: WindowSnapshot, timeoutMs: Int)
    /// Pressed once, never retried.
    case pressMenuItem(MenuItemTarget, window: EmlWindow, guardChecks: [GuardCheck], verify: [WindowCheck], guardTimeoutMs: Int)
    /// Whether to press again is decided only by whether the window is still
    /// open with no sheet, never by what the press returned.
    case pressUntilWindowCloses(
        MenuItemTarget, window: EmlWindow, guardChecks: [GuardCheck], verify: [WindowCheck], guardTimeoutMs: Int,
        maxPresses: Int, readyTimeoutMs: Int, goneTimeoutMs: Int
    )
    case closeWindow(EmlWindow)
}

public enum EmlPlan {
    public static let maxSendPresses = 3

    public static func steps(emlPath: String, send: Bool) -> [EmlStep] {
        let guardChecks = GuardCheck.allCases
        let verify = WindowCheck.allCases
        var steps: [EmlStep] = [
            .requireAccessibility,
            .launchMail(timeoutMs: 10_000),
            .snapshotWindows(.beforeOpen, settle: true),
            .openEml(path: emlPath),
            .waitForNewWindow(.viewer, since: .beforeOpen, timeoutMs: 5_000),
            .snapshotWindows(.beforeCompose, settle: false),
            .pressMenuItem(.sendAgain, window: .viewer, guardChecks: guardChecks, verify: verify, guardTimeoutMs: 3_000),
            .waitForNewWindow(.compose, since: .beforeCompose, timeoutMs: 5_000),
        ]
        if send {
            steps.append(.pressUntilWindowCloses(
                .send, window: .compose, guardChecks: guardChecks, verify: verify, guardTimeoutMs: 3_000,
                maxPresses: maxSendPresses, readyTimeoutMs: 10_000, goneTimeoutMs: 3_000
            ))
        }
        steps.append(.closeWindow(.viewer))
        return steps
    }

    public static func jsonLines(_ steps: [EmlStep]) -> [String] {
        steps.map { planJSONLine(fields($0)) }
    }

    static func fields(_ step: EmlStep) -> [String: Any] {
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
        case let .pressMenuItem(target, window, guardChecks, verify, guardTimeoutMs):
            return [
                "step": "press_menu_item", "item": itemFields(target), "window": window.rawValue,
                "guard": guardChecks.map(\.rawValue), "verify": verify.map(\.rawValue), "guard_timeout_ms": guardTimeoutMs,
            ]
        case let .pressUntilWindowCloses(target, window, guardChecks, verify, guardTimeoutMs, maxPresses, readyTimeoutMs, goneTimeoutMs):
            return [
                "step": "press_until_window_closes", "item": itemFields(target), "window": window.rawValue,
                "guard": guardChecks.map(\.rawValue), "verify": verify.map(\.rawValue), "guard_timeout_ms": guardTimeoutMs,
                "max_presses": maxPresses, "ready_timeout_ms": readyTimeoutMs, "gone_timeout_ms": goneTimeoutMs,
            ]
        case let .closeWindow(window):
            return ["step": "close_window", "window": window.rawValue]
        }
    }

    static func itemFields(_ target: MenuItemTarget) -> [String: Any] {
        ["shortcut": target.shortcutName, "fallback_menu": target.fallbackMenu, "fallback_title": target.fallbackTitle]
    }
}

/// Compact, keys sorted, slashes unescaped: the e2e harness compares dry-run
/// plans line by line with its templates and with `jq -cS` of each line.
func planJSONLine(_ fields: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

public struct EmlPlanPrinter: EmlDelivery {
    let output: (String) -> Void

    public init(output: @escaping (String) -> Void) {
        self.output = output
    }

    public func deliverEml(emlURL: URL, subject: String, send: Bool) throws {
        for line in EmlPlan.jsonLines(EmlPlan.steps(emlPath: emlURL.path, send: send)) {
            output(line)
        }
    }
}
