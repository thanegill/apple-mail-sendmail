import ApplicationServices
import Foundation
import SendmailCore

private let emlURL = URL(fileURLWithPath: "/tmp/sendmail-test/compose-1.eml")

private final class PermissionCounter {
    var checks = 0
}

private final class TraceLog {
    var lines: [String] = []
}

private func delivery(
    _ mail: FakeMail, granted: Bool = true, counter: PermissionCounter = PermissionCounter(), trace: TraceLog = TraceLog()
) -> AXHTMLDelivery {
    AXHTMLDelivery(
        ax: mail,
        workspace: mail,
        clock: mail,
        accessibility: AccessibilityPermission(osMajorVersion: 27) {
            counter.checks += 1
            return granted
        },
        trace: { trace.lines.append($0) }
    )
}

/// Runs the HTML path against `mail` for a message whose Subject is
/// `subject` (by default the title FakeMail shows), and returns the error
/// it threw, if any.
private func runHTML(
    _ mail: FakeMail, send: Bool, subject: String? = nil, granted: Bool = true, trace: TraceLog = TraceLog()
) -> Error? {
    do {
        try delivery(mail, granted: granted, trace: trace).deliverHTML(emlURL: emlURL, subject: subject ?? mail.messageTitle, send: send)
        return nil
    } catch {
        return error
    }
}

private func expectFailure(_ error: Error?, containing text: String, file: StaticString = #file, line: UInt = #line) throws {
    guard let error = error as? DeliveryError else {
        throw TestFailure(message: "expected an DeliveryError containing \"\(text)\", got \(String(describing: error))", file: file, line: line)
    }
    try expect(error.message.contains(text), "expected \"\(text)\" in: \(error.message)", file: file, line: line)
}

private func expectSuccess(_ error: Error?, file: StaticString = #file, line: UInt = #line) throws {
    try expect(error == nil, "expected success, got \(String(describing: error))", file: file, line: line)
}

let axHTMLDeliveryTests = TestSuite(name: "AXHTMLDelivery", cases: [
    // MARK: Happy paths

    TestCase(name: "draft_presses_send_again_once_on_the_viewer_and_leaves_the_compose_open") {
        let mail = FakeMail()
        try expectSuccess(runHTML(mail, send: false))
        try expectEqual(mail.openedURLs, [emlURL])
        try expectEqual(mail.presses, [FakeMail.Press(item: "Send Again", keyWindow: mail.viewerID)])
        try expect(mail.isOpen(mail.composeID), "the draft compose must stay open")
        try expect(mail.sentWindows.isEmpty, "a draft must not be sent")
        try expectEqual(mail.closedByButton, [mail.viewerID!])
    },

    TestCase(name: "send_presses_send_once_on_the_compose_and_succeeds_when_it_closes") {
        let mail = FakeMail()
        try expectSuccess(runHTML(mail, send: true))
        try expectEqual(mail.presses, [
            FakeMail.Press(item: "Send Again", keyWindow: mail.viewerID),
            FakeMail.Press(item: "Send", keyWindow: mail.composeID),
        ])
        try expectEqual(mail.sentWindows, [mail.composeID!])
        try expect(!mail.isOpen(mail.composeID))
        try expectEqual(mail.closedByButton, [mail.viewerID!])
    },

    TestCase(name: "launches_mail_without_activating_when_it_is_not_running") {
        let mail = FakeMail()
        mail.mailRunning = false
        try expectSuccess(runHTML(mail, send: false))
        try expectEqual(mail.launches, 1)
    },

    TestCase(name: "accessibility_denied_touches_neither_mail_nor_launch_services") {
        let mail = FakeMail()
        let counter = PermissionCounter()
        var thrown: Error?
        do {
            try delivery(mail, granted: false, counter: counter).deliverHTML(emlURL: emlURL, subject: mail.messageTitle, send: true)
        } catch {
            thrown = error
        }
        try expect(thrown is AccessibilityNotGranted, "got \(String(describing: thrown))")
        try expectEqual(counter.checks, 1)
        try expectEqual(mail.axCalls, 0)
        try expectEqual(mail.launches, 0)
        try expect(mail.openedURLs.isEmpty)
    },

    TestCase(name: "mail_accessibility_interface_never_answering_times_out_before_opening") {
        let mail = FakeMail()
        mail.axAnswers = false
        try expectFailure(runHTML(mail, send: false), containing: "Mail's accessibility interface did not answer within 10s")
        try expect(mail.openedURLs.isEmpty)
    },

    // MARK: Finding the windows

    TestCase(name: "viewer_never_appearing_times_out_after_5s_without_pressing") {
        let mail = FakeMail()
        mail.viewerAppears = false
        let error = runHTML(mail, send: true)
        try expectFailure(error, containing: "Mail did not open a viewer for the eml within 5s")
        try expect(mail.presses.isEmpty)
    },

    TestCase(name: "stray_standard_window_with_the_viewer_fails_closed_without_pressing") {
        let mail = FakeMail()
        mail.strayWindowWithViewer = true
        try expectFailure(runHTML(mail, send: true), containing: "Mail opened more than one new window while waiting for the eml viewer; refusing to guess which is ours (found 2)")
        try expect(mail.presses.isEmpty)
    },

    TestCase(name: "new_non_standard_window_is_not_taken_for_the_viewer") {
        let mail = FakeMail()
        mail.strayPanelWithViewer = true
        try expectSuccess(runHTML(mail, send: false))
        try expectEqual(mail.presses, [FakeMail.Press(item: "Send Again", keyWindow: mail.viewerID)])
    },

    TestCase(name: "compose_never_appearing_times_out_and_send_again_is_pressed_only_once") {
        let mail = FakeMail()
        mail.composeAppears = false
        try expectFailure(runHTML(mail, send: true), containing: "Compose window did not appear after Send Again within 5s")
        try expectEqual(mail.sendAgainPresses.count, 1)
        try expect(mail.sendPresses.isEmpty)
    },

    // MARK: Key-window guard

    TestCase(name: "wrong_key_window_refuses_and_never_presses_into_the_users_compose") {
        let mail = FakeMail()
        let bystander = mail.addBystanderCompose()
        mail.focusStuckOn = bystander
        try expectFailure(runHTML(mail, send: true), containing: "The eml viewer window did not pass the key-window check within 3s; the Message > Send Again press was not sent. Last failed check: the key window (AXFocusedWindow) is not the eml viewer window")
        try expect(mail.presses.isEmpty, "nothing may be pressed while another window is key: \(mail.presses)")
        try expect(mail.sentWindows.isEmpty, "the user's compose must not be sent")
        try expect(mail.isOpen(bystander))
    },

    TestCase(name: "wrong_main_window_refuses_and_never_presses") {
        let mail = FakeMail()
        mail.mainStuckOn = mail.addBystanderCompose()
        try expectFailure(runHTML(mail, send: false), containing: "Last failed check: the main window (AXMainWindow) is not the eml viewer window")
        try expect(mail.presses.isEmpty)
    },

    TestCase(name: "target_that_is_no_longer_a_standard_window_is_not_pressed") {
        let mail = FakeMail()
        mail.viewerTurnsNonStandardWhenRaised = true
        try expectFailure(runHTML(mail, send: false), containing: "Last failed check: the eml viewer window is not an AXStandardWindow")
        try expect(mail.presses.isEmpty)
    },

    TestCase(name: "mail_not_frontmost_refuses_and_never_presses") {
        let mail = FakeMail()
        mail.refusesFrontmost = true
        try expectFailure(runHTML(mail, send: false), containing: "Last failed check: Mail is not the frontmost app")
        try expect(mail.presses.isEmpty)
    },

    TestCase(name: "sheet_on_the_compose_before_send_refuses_to_press_send") {
        let mail = FakeMail()
        mail.composeArrivesWithSheet = true
        try expectFailure(runHTML(mail, send: true), containing: "Last failed check: the compose window has a sheet open")
        try expect(mail.sendPresses.isEmpty)
        try expect(mail.sentWindows.isEmpty)
    },

    TestCase(name: "plan_runs_every_guard_and_window_check_before_each_press") {
        for send in [false, true] {
            var presses = 0
            for step in HTMLPlan.steps(emlPath: emlURL.path, send: send) {
                switch step {
                case let .pressMenuItem(_, _, checks, verify, _), let .pressUntilWindowCloses(_, _, checks, verify, _, _, _, _):
                    presses += 1
                    try expectEqual(checks, GuardCheck.allCases)
                    try expectEqual(verify, [.titleMatchesSubject])
                default:
                    continue
                }
            }
            try expectEqual(presses, send ? 2 : 1)
        }
    },

    TestCase(name: "compose_closed_before_the_first_send_press_is_an_error") {
        let mail = FakeMail()
        mail.composeClosedByUserAfter = 0.05
        try expectFailure(runHTML(mail, send: true), containing: "The compose window closed before the Message > Send press")
        try expect(mail.sendPresses.isEmpty)
    },

    // MARK: Finding menu items by shortcut

    TestCase(name: "english_menus_find_both_items_by_their_shortcut") {
        let mail = FakeMail()
        let trace = TraceLog()
        try expectSuccess(runHTML(mail, send: true, trace: trace))
        try expectEqual(trace.lines, [
            "pressing Message > Send Again on the eml viewer window, found by its shift-cmd-D shortcut",
            "pressing Message > Send on the compose window, found by its shift-cmd-D shortcut",
        ])
    },

    TestCase(name: "localized_menus_with_the_same_shortcuts_draft_and_send") {
        for send in [false, true] {
            let mail = FakeMail()
            mail.menus = FakeMail.germanMenus
            try expectSuccess(runHTML(mail, send: send))
            var wanted = [FakeMail.Press(item: "Send Again", keyWindow: mail.viewerID)]
            if send { wanted.append(FakeMail.Press(item: "Send", keyWindow: mail.composeID)) }
            try expectEqual(mail.presses, wanted)
            try expectEqual(mail.sentWindows, send ? [mail.composeID!] : [])
        }
    },

    TestCase(name: "two_enabled_items_with_the_shortcut_fail_closed_without_pressing") {
        let mail = FakeMail()
        mail.menus.insert(FakeMail.Menu(title: "Format", items: [
            FakeMail.MenuEntry(title: "Stray", commandCharacter: "D", modifiers: 1),
        ]), at: 1)
        try expectFailure(runHTML(mail, send: true), containing: "Mail has 2 enabled menu items with the shift-cmd-D shortcut; refusing to guess which one is Message > Send Again, and nothing was pressed")
        try expect(mail.presses.isEmpty, "nothing may be pressed when the shortcut is ambiguous: \(mail.presses)")
    },

    TestCase(name: "no_item_with_the_shortcut_falls_back_to_the_english_title") {
        let mail = FakeMail()
        mail.menus = FakeMail.withoutShortcuts(FakeMail.englishMenus)
        let trace = TraceLog()
        try expectSuccess(runHTML(mail, send: true, trace: trace))
        try expectEqual(mail.sentWindows, [mail.composeID!])
        try expectEqual(trace.lines, [
            "pressing Message > Send Again on the eml viewer window, found by its English title (no enabled item has the shift-cmd-D shortcut)",
            "pressing Message > Send on the compose window, found by its English title (no enabled item has the shift-cmd-D shortcut)",
        ])
    },

    TestCase(name: "localized_menus_without_the_shortcut_fail_closed_without_pressing") {
        let mail = FakeMail()
        mail.menus = FakeMail.withoutShortcuts(FakeMail.germanMenus)
        try expectFailure(runHTML(mail, send: false), containing: "Last failed check: no enabled menu item has the shift-cmd-D shortcut, and Mail's Message > Send Again menu item was not found by title")
        try expect(mail.presses.isEmpty)
    },

    TestCase(name: "disabled_item_with_the_shortcut_is_ignored") {
        let mail = FakeMail()
        mail.menus.insert(FakeMail.Menu(title: "Format", items: [
            FakeMail.MenuEntry(title: "Stray", commandCharacter: "D", modifiers: 1, disabled: true),
        ]), at: 1)
        let trace = TraceLog()
        try expectSuccess(runHTML(mail, send: true, trace: trace))
        try expectEqual(mail.presses.map(\.item), ["Send Again", "Send"])
        try expect(trace.lines.allSatisfy { $0.hasSuffix("found by its shift-cmd-D shortcut") }, "\(trace.lines)")
    },

    TestCase(name: "dictation_d_with_other_modifiers_is_not_the_shortcut") {
        let mail = FakeMail()
        mail.menus = FakeMail.germanMenus
        mail.menus[2].items.removeAll { $0.action == .sendAgain }
        mail.menus[2].items.append(FakeMail.MenuEntry(title: "Erneut senden", action: .sendAgain))
        try expectFailure(runHTML(mail, send: false), containing: "no enabled menu item has the shift-cmd-D shortcut")
        try expect(mail.presses.isEmpty, "Start Dictation (D, modifiers 24) must never be pressed: \(mail.presses)")
    },

    TestCase(name: "plan_finds_both_presses_by_shift_cmd_d_with_the_english_title_as_fallback") {
        let targets = HTMLPlan.steps(emlPath: emlURL.path, send: true).compactMap { step -> MenuItemTarget? in
            switch step {
            case let .pressMenuItem(item, _, _, _, _), let .pressUntilWindowCloses(item, _, _, _, _, _, _, _):
                return item
            default:
                return nil
            }
        }
        try expectEqual(targets, [.sendAgain, .send])
        try expectEqual(targets.map(\.shortcutName), ["shift-cmd-D", "shift-cmd-D"])
        try expectEqual(targets.map(\.fallbackName), ["Message > Send Again", "Message > Send"])
    },

    // MARK: Window contents

    TestCase(name: "stray_viewer_for_another_message_in_place_of_ours_is_refused_without_pressing") {
        let mail = FakeMail()
        mail.strayViewerInsteadOfViewer = "Quarterly Report"
        try expectFailure(runHTML(mail, send: true), containing: #"The eml viewer window does not show this message, so it may be a stray window and not ours; the Message > Send Again press was not sent: the eml viewer window's title (AXTitle) is "Quarterly Report", but the message's Subject is "Test Subject""#)
        try expect(mail.presses.isEmpty, "a stray viewer must not be pressed: \(mail.presses)")
        try expect(mail.composeID == nil)
    },

    TestCase(name: "stray_compose_in_place_of_ours_is_refused_before_send") {
        let mail = FakeMail()
        mail.strayComposeInsteadOfCompose = "New Message"
        try expectFailure(runHTML(mail, send: true), containing: #"the Message > Send press was not sent: the compose window's title (AXTitle) is "New Message", but the message's Subject is "Test Subject""#)
        try expect(mail.sendPresses.isEmpty, "a stray compose must not be sent: \(mail.presses)")
        try expect(mail.sentWindows.isEmpty)
    },

    TestCase(name: "matching_viewer_and_compose_titles_are_accepted") {
        for send in [false, true] {
            let mail = FakeMail()
            mail.messageTitle = "Invoice 2026-11 \u{2014} caf\u{e9}"
            let trace = TraceLog()
            try expectSuccess(runHTML(mail, send: send, trace: trace))
            try expectEqual(mail.presses.count, send ? 2 : 1)
            try expect(!trace.lines.contains { $0.contains("not checked") }, "\(trace.lines)")
        }
    },

    TestCase(name: "title_that_differs_only_in_case_is_refused") {
        let mail = FakeMail()
        mail.messageTitle = "test subject"
        try expectFailure(runHTML(mail, send: false, subject: "Test Subject"), containing: #"the eml viewer window's title (AXTitle) is "test subject", but the message's Subject is "Test Subject""#)
        try expect(mail.presses.isEmpty)
    },

    TestCase(name: "title_that_is_only_a_prefix_of_the_subject_is_refused") {
        let mail = FakeMail()
        mail.messageTitle = "Test"
        try expectFailure(runHTML(mail, send: false, subject: "Test Subject"), containing: "does not show this message")
        try expect(mail.presses.isEmpty)
    },

    TestCase(name: "empty_subject_skips_the_title_check_relies_on_the_diff_and_traces_it") {
        for subject in ["", " \n\t "] {
            let mail = FakeMail()
            mail.messageTitle = "Kein Betreff"
            let trace = TraceLog()
            try expectSuccess(runHTML(mail, send: true, subject: subject, trace: trace))
            try expectEqual(mail.presses.map(\.item), ["Send Again", "Send"])
            try expectEqual(trace.lines.filter { $0.contains("no Subject") }, [
                "the message has no Subject, so Mail titles the eml viewer window with a localized placeholder; its title is not checked, and the window diff alone identifies it",
                "the message has no Subject, so Mail titles the compose window with a localized placeholder; its title is not checked, and the window diff alone identifies it",
            ])
        }
    },

    TestCase(name: "subject_whitespace_is_normalized_on_both_sides") {
        let cases: [(subject: String, title: String)] = [
            ("  Weekly\n report\t\tfor  you  ", "Weekly report for you"),
            ("Weekly report for you", " Weekly  report\nfor you "),
            ("Weekly\r\n report", "Weekly report"),
        ]
        for (subject, title) in cases {
            let mail = FakeMail()
            mail.messageTitle = title
            try expectSuccess(runHTML(mail, send: true, subject: subject))
            try expectEqual(mail.sentWindows, [mail.composeID!])
        }
    },

    TestCase(name: "normalized_title_collapses_whitespace_runs_and_trims") {
        try expectEqual(WindowCheck.normalizedTitle("  a \n\t b  c\r\n"), "a b c")
        try expectEqual(WindowCheck.normalizedTitle(" \n "), "")
        try expectEqual(WindowCheck.normalizedTitle("A b"), "A b")
    },

    TestCase(name: "compose_title_that_settles_on_the_subject_within_the_guard_timeout_is_accepted") {
        let mail = FakeMail()
        mail.composeTitleDelay = 1
        try expectSuccess(runHTML(mail, send: true))
        try expectEqual(mail.sentWindows, [mail.composeID!])
    },

    TestCase(name: "no_subject_send_confirmation_sheet_fails_closed_saying_send_needs_a_subject") {
        let mail = FakeMail()
        mail.messageTitle = "Kein Betreff"
        mail.sheetOnSend = true
        try expectFailure(runHTML(mail, send: true, subject: ""), containing: "Mail is asking to confirm sending a message with no Subject (a sheet opened on the compose window after the Message > Send press); it is not confirmed, and the message was not sent. HTML --send needs a Subject: add a non-empty Subject header, or leave out --send to get a draft")
        try expectEqual(mail.sendPresses.count, 1)
        try expect(mail.sentWindows.isEmpty)
    },

    // MARK: Send retry

    TestCase(name: "send_ignored_once_then_accepted_presses_twice_and_succeeds") {
        let mail = FakeMail()
        mail.sendIgnoredTimes = 1
        try expectSuccess(runHTML(mail, send: true))
        try expectEqual(mail.sendPresses.count, 2)
        try expectEqual(mail.sentWindows, [mail.composeID!])
    },

    TestCase(name: "press_reporting_cannot_complete_after_acting_is_not_retried") {
        let mail = FakeMail()
        mail.sendPressResult = .cannotComplete
        try expectSuccess(runHTML(mail, send: true))
        try expectEqual(mail.sendPresses.count, 1)
        try expectEqual(mail.sentWindows, [mail.composeID!])
    },

    TestCase(name: "press_reporting_cannot_complete_without_acting_is_retried_while_the_compose_is_open") {
        let mail = FakeMail()
        mail.sendPressResult = .cannotComplete
        mail.sendIgnoredTimes = 1
        try expectSuccess(runHTML(mail, send: true))
        try expectEqual(mail.sendPresses.count, 2)
        try expectEqual(mail.sentWindows, [mail.composeID!])
    },

    TestCase(name: "send_never_taken_stops_after_three_presses_and_fails") {
        let mail = FakeMail()
        mail.sendIgnoredTimes = 100
        try expectFailure(runHTML(mail, send: true), containing: "Send did not complete: the compose window is still open after 3 Message > Send presses")
        try expectEqual(mail.sendPresses.count, 3)
        try expect(mail.isOpen(mail.composeID))
    },

    TestCase(name: "sheet_after_send_fails_at_once_without_pressing_again") {
        let mail = FakeMail()
        mail.sheetOnSend = true
        try expectFailure(runHTML(mail, send: true), containing: "A sheet is open on the compose window after the Message > Send press")
        try expectEqual(mail.sendPresses.count, 1)
        try expect(mail.sentWindows.isEmpty)
    },

    TestCase(name: "send_menu_item_never_enabled_fails_after_10s_without_pressing") {
        let mail = FakeMail()
        mail.sendNeverEnabled = true
        try expectFailure(runHTML(mail, send: true), containing: "Mail's Message > Send menu item (shift-cmd-D) did not become available within 10s; the compose was not sent")
        try expect(mail.sendPresses.isEmpty)
    },

    TestCase(name: "every_press_lands_on_the_window_the_step_targets") {
        for send in [false, true] {
            let mail = FakeMail()
            mail.addBystanderCompose()
            mail.sendIgnoredTimes = 1
            try expectSuccess(runHTML(mail, send: send))
            for press in mail.presses {
                let wanted = press.item == "Send Again" ? mail.viewerID : mail.composeID
                try expectEqual(press.keyWindow, wanted)
            }
        }
    },

    // MARK: Plan and dry run

    TestCase(name: "draft_plan_prints_one_json_object_per_step") {
        let lines = HTMLPlan.jsonLines(HTMLPlan.steps(emlPath: "/tmp/x/compose-1.eml", send: false))
        try expectEqual(lines, draftPlanLines)
    },

    TestCase(name: "send_plan_adds_the_bounded_send_step_before_closing_the_viewer") {
        let lines = HTMLPlan.jsonLines(HTMLPlan.steps(emlPath: "/tmp/x/compose-1.eml", send: true))
        var expected = draftPlanLines
        expected.insert(sendPlanLine, at: expected.count - 1)
        try expectEqual(lines, expected)
    },

    TestCase(name: "plan_printer_prints_the_plan_without_touching_mail") {
        var printed: [String] = []
        try HTMLPlanPrinter { printed.append($0) }.deliverHTML(emlURL: URL(fileURLWithPath: "/tmp/x/compose-1.eml"), subject: "s", send: true)
        try expectEqual(printed, HTMLPlan.jsonLines(HTMLPlan.steps(emlPath: "/tmp/x/compose-1.eml", send: true)))
    },

    TestCase(name: "plan_path_with_quotes_and_backslashes_stays_one_json_string") {
        let path = "/tmp/odd \"dir\" \\ caf\u{e9}/compose.eml"
        let line = HTMLPlan.jsonLines([.openEml(path: path)])[0]
        let decoded = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        try expectEqual(decoded?["path"] as? String, path)
        try expect(!line.contains("\n"))
    },
])

private let draftPlanLines = [
    #"{"step":"require_accessibility"}"#,
    #"{"activates":false,"step":"launch_mail","timeout_ms":10000}"#,
    #"{"settle":true,"snapshot":"before_open","step":"snapshot_windows"}"#,
    #"{"activates":true,"path":"/tmp/x/compose-1.eml","step":"open_eml"}"#,
    #"{"since":"before_open","step":"wait_for_new_window","timeout_ms":5000,"window":"viewer"}"#,
    #"{"settle":false,"snapshot":"before_compose","step":"snapshot_windows"}"#,
    #"{"guard":["frontmost","focused_window","main_window","standard_window","no_sheet"],"guard_timeout_ms":3000,"item":{"fallback_menu":"Message","fallback_title":"Send Again","shortcut":"shift-cmd-D"},"step":"press_menu_item","verify":["title_matches_subject"],"window":"viewer"}"#,
    #"{"since":"before_compose","step":"wait_for_new_window","timeout_ms":5000,"window":"compose"}"#,
    #"{"step":"close_window","window":"viewer"}"#,
]

private let sendPlanLine = #"{"gone_timeout_ms":3000,"guard":["frontmost","focused_window","main_window","standard_window","no_sheet"],"guard_timeout_ms":3000,"item":{"fallback_menu":"Message","fallback_title":"Send","shortcut":"shift-cmd-D"},"max_presses":3,"ready_timeout_ms":10000,"step":"press_until_window_closes","verify":["title_matches_subject"],"window":"compose"}"#
