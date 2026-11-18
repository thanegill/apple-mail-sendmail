import ApplicationServices
import CoreServices
import Foundation

/// The two grants `--check-permissions` reads, so tests can answer them
/// without touching Accessibility or Apple Events.
public protocol PermissionProbe {
    /// Whether this process may drive another app's UI, which the .eml path
    /// needs. Never prompts.
    func accessibilityGranted() -> Bool
    /// Whether this process may send Apple Events to Mail, which --no-ui
    /// needs, asking the user when macOS can. Mail must be running.
    /// Returns the OSStatus: 0 granted, -1743 denied, -1744 not asked yet,
    /// -600 Mail not running.
    func mailAutomationStatus() -> Int
}

/// What `--check-permissions` found out about Automation for Mail.
public enum AutomationStatus: Equatable {
    case granted
    /// -1743: denied, or never asked and macOS could not ask.
    case denied
    /// -1744: macOS has not asked yet and would need to.
    case notAsked
    /// Mail could not be started, so the grant could not be checked.
    case mailDidNotStart(String)
    /// Mail did not answer within the wait (-600 or -609).
    case mailNotAnswering(Int)
    case failed(Int)
}

/// The result of `--check-permissions`: what it printed and how it exits.
public struct PermissionReport: Equatable {
    public let accessibilityGranted: Bool
    public let automation: AutomationStatus
    public let osMajorVersion: Int

    public var allGranted: Bool { accessibilityGranted && automation == .granted }

    /// 0 when both grants are in place, 78 (`EX_CONFIG`) otherwise.
    public var exitCode: ExitCode { allGranted ? .ok : .config }

    public var text: String {
        var lines = [
            "apple-mail-sendmail permission check (nothing is sent)",
            "",
            "  Accessibility, for every message:      \(accessibilityGranted ? "granted" : "NOT GRANTED")",
            "  Automation for Mail, only for --no-ui: \(automationSummary)",
            "",
            "macOS charges both grants to the responsible process, not to this",
            "binary: usually the app it was started from, such as Terminal, iTerm2",
            "or an editor's terminal. Under cron, launchd, SSH or a remote agent it",
            "is that launcher or the binary itself, which usually cannot show a",
            "prompt, so Automation is refused (-1743) without asking. macOS has no",
            "public API that names the responsible process, so this check cannot;",
            "grant the app that will run apple-mail-sendmail, or run this check",
            "from it.",
        ]
        let fixes = fixInstructions
        if fixes.isEmpty {
            lines += ["", "Everything apple-mail-sendmail needs is granted."]
        } else {
            lines += ["", "To fix:"] + fixes
        }
        return lines.joined(separator: "\n")
    }

    var automationSummary: String {
        switch automation {
        case .granted: return "granted"
        case .denied: return "NOT GRANTED (-1743)"
        case .notAsked: return "NOT GRANTED: macOS has not asked yet (-1744)"
        case .mailDidNotStart: return "UNKNOWN: Mail did not start"
        case let .mailNotAnswering(code): return "UNKNOWN: Mail did not answer (\(code))"
        case let .failed(code): return "UNKNOWN: the check failed (\(code))"
        }
    }

    var fixInstructions: [String] {
        var fixes: [String] = []
        if !accessibilityGranted {
            let pane = AccessibilityNotGranted(osMajorVersion: osMajorVersion).settingsLocation
            fixes += [
                "- Accessibility, needed for every message: open",
                "    \(pane)",
                "  and turn on the app that runs apple-mail-sendmail, or add it with the",
                "  + button if it is not listed.",
            ]
        }
        switch automation {
        case .granted:
            break
        case .denied, .notAsked:
            fixes += [
                "- Automation for Mail, needed only for --no-ui: open",
                "    System Settings > Privacy & Security > Automation",
                "  and, under the app that runs apple-mail-sendmail, turn on Mail. An app",
                "  is listed there only after macOS has asked it, and the list has no +",
                "  button: if the app is missing, run",
                "    apple-mail-sendmail --check-permissions",
                "  from it and allow the prompt. To be asked again after a refusal, run",
                "  `tccutil reset AppleEvents <the app's bundle ID>` first, for example",
                "  `tccutil reset AppleEvents com.apple.Terminal`.",
            ]
        case let .mailDidNotStart(reason):
            fixes += [
                "- Automation for Mail could not be checked because Mail did not start",
                "  (\(reason)). Open Mail once, then run this check again.",
            ]
        case .mailNotAnswering, .failed:
            fixes += [
                "- Automation for Mail could not be checked. Make sure Mail opens",
                "  normally, then run this check again.",
            ]
        }
        return fixes
    }
}

public enum PermissionCheck {
    /// How long to wait for a just-launched Mail to answer the Automation check.
    static let mailAnswerTimeout: TimeInterval = 10

    /// Checks Accessibility, then starts Mail without activating it if it is
    /// not running and checks Automation for Mail, which may show macOS's
    /// prompt. Sends no message.
    public static func run(probe: PermissionProbe, workspace: MailWorkspace, clock: Clock, osMajorVersion: Int) -> PermissionReport {
        let accessibility = probe.accessibilityGranted()
        return PermissionReport(
            accessibilityGranted: accessibility,
            automation: automationStatus(probe: probe, workspace: workspace, clock: clock),
            osMajorVersion: osMajorVersion
        )
    }

    static func automationStatus(probe: PermissionProbe, workspace: MailWorkspace, clock: Clock) -> AutomationStatus {
        do {
            _ = try workspace.ensureMailRunning(clock: clock, timeout: mailAnswerTimeout)
        } catch {
            return .mailDidNotStart("\(error)")
        }
        var lastStatus = 0
        let answered = clock.poll(timeout: mailAnswerTimeout, interval: 0.25) { () -> Int? in
            lastStatus = probe.mailAutomationStatus()
            return [-600, -609].contains(lastStatus) ? nil : lastStatus
        }
        switch answered {
        case nil: return .mailNotAnswering(lastStatus)
        case 0: return .granted
        case -1743: return .denied
        case -1744: return .notAsked
        case let status?: return .failed(status)
        }
    }
}

/// `PermissionProbe` over `AXIsProcessTrusted` and
/// `AEDeterminePermissionToAutomateTarget`.
public struct SystemPermissionProbe: PermissionProbe {
    public init() {}

    public func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    public func mailAutomationStatus() -> Int {
        let mail = NSAppleEventDescriptor(bundleIdentifier: AppleEventBuilder.mailBundleID)
        return Int(AEDeterminePermissionToAutomateTarget(mail.aeDesc, typeWildCard, typeWildCard, true))
    }
}
