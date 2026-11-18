import Foundation

/// What the binary prints, and how it exits, when delivery throws.
public struct FailureReport: Equatable {
    public let message: String
    public let exitCode: ExitCode

    public init(_ error: Error) {
        switch error {
        case let failure as AppleEventError where failure.code == -1743:
            message = "Mail.app automation denied. Grant permission in System Settings → Privacy & Security → Automation. (\(failure.message))"
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
        case let failure as DeliveryError:
            message = failure.message
            exitCode = .osErr
        default:
            message = "delivery failed: \(error)"
            exitCode = .osErr
        }
    }
}
