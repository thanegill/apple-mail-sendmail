import Foundation

public struct FailureReport: Equatable {
    public let message: String
    public let exitCode: ExitCode

    public init(_ error: Error) {
        switch error {
        case let failure as AppleEventError where failure.code == -1743:
            message = "Mail.app automation denied. --no-ui drives Mail with Apple Events, which needs Automation for Mail: grant it in System Settings → Privacy & Security → Automation, or run without --no-ui, which needs Accessibility instead. (\(failure.message))"
            exitCode = .config
        case let failure as AppleEventError where failure.code == -600:
            // -600 means the event never reached Mail, so nothing was sent by
            // it and an MTA retry cannot send twice.
            message = "Mail.app is not running, or quit before the message was handed to it (-600). Start Mail and try again."
            exitCode = .tempFail
        case let failure as AppleEventError:
            message = "Mail.app rejected the message (\(failure.code)): \(failure.message)"
            exitCode = .osErr
        case let denied as AccessibilityNotGranted:
            message = denied.description
            exitCode = .config
        case let refused as HTMLNeedsUI:
            message = refused.description
            exitCode = .usage
        case let refused as SendNeedsSubject:
            message = refused.description
            exitCode = .dataErr
        case let failure as DeliveryError:
            message = failure.message
            exitCode = .osErr
        default:
            message = "delivery failed: \(error)"
            exitCode = .osErr
        }
    }
}
