import Foundation
import SendmailCore

/// Answers the permission checks from fixed values and records each
/// Automation check, with whether Mail was running at the time.
private final class FakePermissionProbe: PermissionProbe {
    let accessibility: Bool
    /// One answer per Automation check; the last one repeats.
    let automationAnswers: [Int]
    let mail: MailWorkspace
    private(set) var accessibilityChecks = 0
    private(set) var mailRunningAtEachAutomationCheck: [Bool] = []

    init(accessibility: Bool, automation: [Int], mail: MailWorkspace) {
        self.accessibility = accessibility
        self.automationAnswers = automation
        self.mail = mail
    }

    func accessibilityGranted() -> Bool {
        accessibilityChecks += 1
        return accessibility
    }

    func mailAutomationStatus() -> Int {
        mailRunningAtEachAutomationCheck.append(mail.runningMailPID() != nil)
        let index = min(mailRunningAtEachAutomationCheck.count, automationAnswers.count) - 1
        return automationAnswers[index]
    }
}

private struct UnlaunchableMail: MailWorkspace {
    func runningMailPID() -> Int32? { nil }
    func launchMail(timeout: TimeInterval) throws { throw DeliveryError("Launch Services cannot find Mail (com.apple.mail)") }
    func open(_ url: URL, timeout: TimeInterval) throws { throw DeliveryError("unexpected open") }
}

private func check(accessibility: Bool = true, automation: [Int] = [0], mail: FakeMail = FakeMail(), osMajorVersion: Int = 27) -> (PermissionReport, FakePermissionProbe) {
    let probe = FakePermissionProbe(accessibility: accessibility, automation: automation, mail: mail)
    return (PermissionCheck.run(probe: probe, workspace: mail, clock: mail, osMajorVersion: osMajorVersion), probe)
}

private let automationPane = "System Settings > Privacy & Security > Automation"

let permissionCheckTests = TestSuite(name: "PermissionCheck", cases: [
    TestCase(name: "both_granted_exits_0_with_no_fixes") {
        let (report, probe) = check()
        try expectEqual(report.accessibilityGranted, true)
        try expectEqual(report.automation, .granted)
        try expectEqual(report.exitCode, .ok)
        try expectEqual(probe.accessibilityChecks, 1)
        try expect(report.text.contains("Accessibility, for every message:      granted"), report.text)
        try expect(report.text.contains("Automation for Mail, only for --no-ui: granted"), report.text)
        try expect(report.text.contains("Everything apple-mail-sendmail needs is granted."), report.text)
        try expect(!report.text.contains("To fix:"), report.text)
    },

    TestCase(name: "missing_accessibility_exits_78_and_names_device_control_and_data_access_on_macos_27") {
        let (report, probe) = check(accessibility: false, osMajorVersion: 27)
        try expectEqual(report.exitCode, .config)
        try expectEqual(probe.mailRunningAtEachAutomationCheck.count, 1)
        try expect(report.text.contains("Accessibility, for every message:      NOT GRANTED"), report.text)
        try expect(report.text.contains("- Accessibility, needed for every message: open\n    System Settings > Privacy & Security > Device Control and Data Access\n"), report.text)
        try expect(!report.text.contains("- Automation for Mail"), "Automation is granted and needs no fix:\n\(report.text)")
    },

    TestCase(name: "missing_accessibility_names_the_accessibility_pane_before_macos_27") {
        let (report, _) = check(accessibility: false, osMajorVersion: 26)
        try expect(report.text.contains("- Accessibility, needed for every message: open\n    System Settings > Privacy & Security > Accessibility\n"), report.text)
        try expect(!report.text.contains("Device Control and Data Access"), report.text)
    },

    TestCase(name: "denied_automation_exits_78_and_names_the_automation_pane") {
        let (report, _) = check(automation: [-1743])
        try expectEqual(report.automation, .denied)
        try expectEqual(report.exitCode, .config)
        try expect(report.text.contains("Automation for Mail, only for --no-ui: NOT GRANTED (-1743)"), report.text)
        try expect(report.text.contains("- Automation for Mail, needed only for --no-ui: open\n    \(automationPane)\n"), report.text)
        try expect(report.text.contains("under the app that runs apple-mail-sendmail, turn on Mail."), report.text)
        try expect(report.text.contains("\n    apple-mail-sendmail --check-permissions\n"), report.text)
        try expect(!report.text.contains("- Accessibility, needed"), report.text)
    },

    TestCase(name: "automation_not_asked_yet_is_not_granted") {
        let (report, _) = check(automation: [-1744])
        try expectEqual(report.automation, .notAsked)
        try expectEqual(report.exitCode, .config)
        try expect(report.text.contains("macOS has not asked yet (-1744)"), report.text)
        try expect(report.text.contains(automationPane), report.text)
    },

    TestCase(name: "both_missing_lists_both_fixes") {
        let (report, _) = check(accessibility: false, automation: [-1743])
        try expectEqual(report.exitCode, .config)
        try expect(report.text.contains("- Accessibility, needed") && report.text.contains("- Automation for Mail"), report.text)
    },

    TestCase(name: "starts_mail_without_activating_it_before_the_automation_check") {
        let mail = FakeMail()
        mail.mailRunning = false
        let (report, probe) = check(mail: mail)
        try expectEqual(report.automation, .granted)
        try expectEqual(mail.launches, 1)
        try expect(mail.openedURLs.isEmpty, "the check must open nothing in Mail")
        try expectEqual(mail.axCalls, 0)
        try expectEqual(probe.mailRunningAtEachAutomationCheck, [true])
    },

    TestCase(name: "does_not_launch_a_running_mail") {
        let mail = FakeMail()
        _ = check(mail: mail)
        try expectEqual(mail.launches, 0)
    },

    TestCase(name: "retries_while_a_just_launched_mail_is_not_answering") {
        let mail = FakeMail()
        mail.mailRunning = false
        let (report, probe) = check(automation: [-600, -609, 0], mail: mail)
        try expectEqual(report.automation, .granted)
        try expectEqual(report.exitCode, .ok)
        try expectEqual(probe.mailRunningAtEachAutomationCheck.count, 3)
    },

    TestCase(name: "gives_up_when_mail_never_answers") {
        let mail = FakeMail()
        let (report, probe) = check(automation: [-600], mail: mail)
        try expectEqual(report.automation, .mailNotAnswering(-600))
        try expectEqual(report.exitCode, .config)
        try expect(mail.now >= 10 && mail.now < 10.5, "gave up after \(mail.now)s")
        try expect(probe.mailRunningAtEachAutomationCheck.count > 2)
        try expect(report.text.contains("UNKNOWN: Mail did not answer (-600)"), report.text)
        try expect(report.text.contains("- Automation for Mail could not be checked."), report.text)
    },

    TestCase(name: "mail_that_cannot_start_is_reported_without_an_automation_check") {
        let clock = FakeMail()
        let mail = UnlaunchableMail()
        let probe = FakePermissionProbe(accessibility: true, automation: [0], mail: mail)
        let report = PermissionCheck.run(probe: probe, workspace: mail, clock: clock, osMajorVersion: 27)
        try expectEqual(report.automation, .mailDidNotStart("Launch Services cannot find Mail (com.apple.mail)"))
        try expectEqual(report.exitCode, .config)
        try expect(probe.mailRunningAtEachAutomationCheck.isEmpty)
        try expect(report.text.contains("UNKNOWN: Mail did not start"), report.text)
        try expect(report.text.contains("Launch Services cannot find Mail"), report.text)
    },

    TestCase(name: "unexpected_automation_status_is_not_granted") {
        let (report, _) = check(automation: [-50])
        try expectEqual(report.automation, .failed(-50))
        try expectEqual(report.exitCode, .config)
        try expect(report.text.contains("UNKNOWN: the check failed (-50)"), report.text)
    },

    TestCase(name: "report_explains_the_responsible_process_and_sends_nothing") {
        for (accessibility, automation) in [(true, 0), (false, -1743)] {
            let (report, _) = check(accessibility: accessibility, automation: [automation])
            try expect(report.text.hasPrefix("apple-mail-sendmail permission check (nothing is sent)"), report.text)
            try expect(report.text.contains("macOS charges both grants to the responsible process"), report.text)
            try expect(report.text.contains("no\npublic API that names the responsible process"), report.text)
        }
    },
])
