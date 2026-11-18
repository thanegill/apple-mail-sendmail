import Foundation
import SendmailCore

private final class PermissionProbe {
    var checks = 0
    let granted: Bool
    init(granted: Bool) { self.granted = granted }

    func permission(osMajorVersion: Int = 26) -> AccessibilityPermission {
        AccessibilityPermission(osMajorVersion: osMajorVersion) { [self] in
            checks += 1
            return granted
        }
    }
}

private final class EventLog {
    let recorder = AppleEventRecorder()
    var scripts: [RecordedEvent] { recorder.events }
}

private func message(html: Bool) -> ParsedMessage {
    var msg = ParsedMessage()
    msg.subject = "a11y"
    msg.to = [ParsedAddress(displayName: nil, address: "u@example.test")]
    msg.body = "plain"
    if html { msg.htmlBody = "<p>rich</p>" }
    return msg
}

private func deliver(
    html: Bool, probe: PermissionProbe, log: EventLog, mail: FakeMail = FakeMail(), osMajorVersion: Int = 26, options: Options = Options()
) throws {
    let tmp = try TempDir()
    defer { tmp.cleanup() }
    let automation = MailAutomation(
        plain: AppleEventPlainDelivery(events: log.recorder, workspace: mail, clock: mail),
        eml: AXEmlDelivery(ax: mail, workspace: mail, clock: mail, accessibility: probe.permission(osMajorVersion: osMajorVersion))
    )
    try MailDriver.deliver(message(html: html), emlBytes: Data("Subject: a11y\r\n\r\n<p>rich</p>".utf8), options: options, tmp: tmp, automation: automation)
}

let accessibilityTests = TestSuite(name: "Accessibility", cases: [
    TestCase(name: "html_path_refuses_before_touching_mail_when_not_granted") {
        let probe = PermissionProbe(granted: false)
        let log = EventLog()
        let mail = FakeMail()
        var thrown: Error?
        do {
            try deliver(html: true, probe: probe, log: log, mail: mail)
        } catch {
            thrown = error
        }
        try expect(thrown is AccessibilityNotGranted, "expected AccessibilityNotGranted, got \(String(describing: thrown))")
        try expectEqual(probe.checks, 1)
        try expectEqual(mail.axCalls, 0)
        try expect(mail.openedURLs.isEmpty && log.scripts.isEmpty, "nothing may reach Mail without Accessibility")
    },

    TestCase(name: "html_path_checks_once_then_drives_mail_when_granted") {
        let probe = PermissionProbe(granted: true)
        let log = EventLog()
        let mail = FakeMail()
        mail.messageTitle = "a11y"
        try deliver(html: true, probe: probe, log: log, mail: mail)
        try expectEqual(probe.checks, 1)
        try expect(log.scripts.isEmpty)
        try expectEqual(mail.sendAgainPresses.count, 1)
    },

    TestCase(name: "plain_message_refuses_before_touching_mail_when_not_granted") {
        let probe = PermissionProbe(granted: false)
        let log = EventLog()
        let mail = FakeMail()
        var thrown: Error?
        do {
            try deliver(html: false, probe: probe, log: log, mail: mail)
        } catch {
            thrown = error
        }
        try expect(thrown is AccessibilityNotGranted, "expected AccessibilityNotGranted, got \(String(describing: thrown))")
        try expectEqual(probe.checks, 1)
        try expectEqual(mail.axCalls, 0)
        try expect(mail.openedURLs.isEmpty && log.scripts.isEmpty, "nothing may reach Mail without Accessibility")
    },

    TestCase(name: "plain_message_drives_mail_through_send_again_when_granted") {
        let probe = PermissionProbe(granted: true)
        let log = EventLog()
        let mail = FakeMail()
        mail.messageTitle = "a11y"
        try deliver(html: false, probe: probe, log: log, mail: mail)
        try expectEqual(probe.checks, 1)
        try expect(log.scripts.isEmpty)
        try expectEqual(mail.sendAgainPresses.count, 1)
    },

    TestCase(name: "no_ui_never_checks_accessibility") {
        let probe = PermissionProbe(granted: false)
        let log = EventLog()
        let mail = FakeMail()
        try deliver(html: false, probe: probe, log: log, mail: mail, options: noUIOptions())
        try expectEqual(probe.checks, 0)
        try expectEqual(mail.axCalls, 0)
        try expectEqual(log.scripts.first?.params["kocl"], .type("bcke"))
    },

    TestCase(name: "error_offers_no_ui_for_plain_text") {
        let error = AccessibilityNotGranted(osMajorVersion: 27)
        try expect(error.description.contains("--no-ui"), error.description)
        try expect(error.description.contains("Automation for Mail"), error.description)
    },

    TestCase(name: "error_names_the_accessibility_pane_before_macos_27") {
        for osMajorVersion in [13, 14, 15, 26] {
            let error = AccessibilityNotGranted(osMajorVersion: osMajorVersion)
            try expectEqual(error.settingsLocation, "System Settings > Privacy & Security > Accessibility")
            try expect(error.description.contains("Privacy & Security > Accessibility."), "macOS \(osMajorVersion): \(error.description)")
        }
    },

    TestCase(name: "error_names_device_control_and_data_access_from_macos_27") {
        for osMajorVersion in [27, 28] {
            let error = AccessibilityNotGranted(osMajorVersion: osMajorVersion)
            try expectEqual(error.settingsLocation, "System Settings > Privacy & Security > Device Control and Data Access")
            try expect(error.description.contains("Device Control and Data Access."), "macOS \(osMajorVersion): \(error.description)")
            try expect(!error.description.contains("Privacy & Security > Accessibility"))
        }
    },

    TestCase(name: "refusal_carries_the_os_version_it_was_checked_on") {
        let probe = PermissionProbe(granted: false)
        var thrown: AccessibilityNotGranted?
        do {
            try deliver(html: true, probe: probe, log: EventLog(), osMajorVersion: 27)
        } catch let error as AccessibilityNotGranted {
            thrown = error
        }
        try expectEqual(thrown?.settingsLocation, "System Settings > Privacy & Security > Device Control and Data Access")
    },
])
