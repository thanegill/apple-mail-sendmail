import Foundation
import SendmailCore

private struct OtherError: Error {}

let failureReportTests = TestSuite(name: "FailureReport", cases: [
    TestCase(name: "automation_denied_keeps_the_automation_wording_and_exits_config") {
        let report = FailureReport(AppleEventError(code: -1743, message: "Not authorized to send Apple events to Mail."))
        try expectEqual(report.exitCode, .config)
        try expectEqual(report.message, "Mail.app automation denied. Grant permission in System Settings → Privacy & Security → Automation. (Not authorized to send Apple events to Mail.)")
    },

    TestCase(name: "mail_not_running_is_a_temporary_failure_naming_minus_600") {
        let report = FailureReport(AppleEventError(code: -600, message: "procNotFound"))
        try expectEqual(report.exitCode, .tempFail)
        try expect(report.message.contains("Mail.app is not running"), report.message)
        try expect(report.message.contains("(-600)"), report.message)
    },

    TestCase(name: "other_apple_event_errors_name_their_code_and_exit_oserr") {
        let report = FailureReport(AppleEventError(code: -10000, message: "Apple event handler failed."))
        try expectEqual(report.exitCode, .osErr)
        try expectEqual(report.message, "Mail.app rejected the message (-10000): Apple event handler failed.")
    },

    TestCase(name: "accessibility_denied_exits_config_with_its_own_message") {
        let denied = AccessibilityNotGranted(osMajorVersion: 27)
        let report = FailureReport(denied)
        try expectEqual(report.exitCode, .config)
        try expectEqual(report.message, denied.description)
    },

    TestCase(name: "delivery_errors_print_their_message_and_exit_oserr") {
        let report = FailureReport(DeliveryError("Compose window did not appear after Send Again within 5s"))
        try expectEqual(report, FailureReport(DeliveryError("Compose window did not appear after Send Again within 5s")))
        try expectEqual(report.exitCode, .osErr)
        try expectEqual(report.message, "Compose window did not appear after Send Again within 5s")
    },

    TestCase(name: "reply_carrying_an_error_number_throws_it") {
        let reply = NSAppleEventDescriptor.record()
        reply.setDescriptor(NSAppleEventDescriptor(int32: -1728), forKeyword: fourCC("errn"))
        reply.setDescriptor(NSAppleEventDescriptor(string: "Can't get outgoing message id 7."), forKeyword: fourCC("errs"))
        var thrown: AppleEventError?
        do {
            _ = try SystemAppleEventSender.checked(reply)
        } catch let error as AppleEventError {
            thrown = error
        }
        try expectEqual(thrown, AppleEventError(code: -1728, message: "Can't get outgoing message id 7."))
    },

    TestCase(name: "reply_without_an_error_number_passes_through") {
        let reply = NSAppleEventDescriptor.record()
        reply.setDescriptor(NSAppleEventDescriptor(boolean: true), forKeyword: fourCC("----"))
        let passed = try SystemAppleEventSender.checked(reply)
        try expect(passed === reply)
        let zero = NSAppleEventDescriptor.record()
        zero.setDescriptor(NSAppleEventDescriptor(int32: 0), forKeyword: fourCC("errn"))
        let passedZero = try SystemAppleEventSender.checked(zero)
        try expect(passedZero === zero)
    },

    TestCase(name: "unknown_errors_exit_oserr") {
        try expectEqual(FailureReport(OtherError()).exitCode, .osErr)
    },
])
