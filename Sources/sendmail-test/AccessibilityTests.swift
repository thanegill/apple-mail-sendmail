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

private final class ScriptLog {
    var scripts: [String] = []
    func run(_ source: String) throws { scripts.append(source) }
}

private func message(html: Bool) -> ParsedMessage {
    var msg = ParsedMessage()
    msg.subject = "a11y"
    msg.to = [ParsedAddress(displayName: nil, address: "u@example.test")]
    msg.body = "plain"
    if html { msg.htmlBody = "<p>rich</p>" }
    return msg
}

private func deliver(html: Bool, probe: PermissionProbe, log: ScriptLog, osMajorVersion: Int = 26) throws {
    let tmp = try TempDir()
    defer { tmp.cleanup() }
    let automation = AppleScriptMailAutomation(
        staging: tmp,
        accessibility: probe.permission(osMajorVersion: osMajorVersion),
        runner: log.run
    )
    try MailDriver.deliver(message(html: html), emlBytes: Data("Subject: a11y\r\n\r\n<p>rich</p>".utf8), options: Options(), tmp: tmp, automation: automation)
}

let accessibilityTests = TestSuite(name: "Accessibility", cases: [
    TestCase(name: "html_path_refuses_before_any_script_runs_when_not_granted") {
        let probe = PermissionProbe(granted: false)
        let log = ScriptLog()
        var thrown: Error?
        do {
            try deliver(html: true, probe: probe, log: log)
        } catch {
            thrown = error
        }
        try expect(thrown is AccessibilityNotGranted, "expected AccessibilityNotGranted, got \(String(describing: thrown))")
        try expectEqual(probe.checks, 1)
        try expect(log.scripts.isEmpty, "no script may run without Accessibility")
    },

    TestCase(name: "html_path_checks_once_then_runs_its_script_when_granted") {
        let probe = PermissionProbe(granted: true)
        let log = ScriptLog()
        try deliver(html: true, probe: probe, log: log)
        try expectEqual(probe.checks, 1)
        try expectEqual(log.scripts.count, 1)
        try expect(log.scripts[0].contains("click menu item \"Send Again\""))
    },

    TestCase(name: "plain_path_never_checks_accessibility") {
        let probe = PermissionProbe(granted: false)
        let log = ScriptLog()
        try deliver(html: false, probe: probe, log: log)
        try expectEqual(probe.checks, 0)
        try expectEqual(log.scripts.count, 1)
        try expect(log.scripts[0].contains("make new outgoing message"))
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
            try deliver(html: true, probe: probe, log: ScriptLog(), osMajorVersion: 27)
        } catch let error as AccessibilityNotGranted {
            thrown = error
        }
        try expectEqual(thrown?.settingsLocation, "System Settings > Privacy & Security > Device Control and Data Access")
    },
])
