import Foundation
import SendmailCore

private final class Recorder {
    var scripts: [String] = []
    func run(_ source: String) throws {
        scripts.append(source)
        capturedMailDriverScripts.append(CapturedScript(testName: currentTestName, source: source))
    }
}

private func withTempDir(_ body: (TempDir) throws -> Void) throws {
    let tmp = try TempDir()
    defer { tmp.cleanup() }
    try body(tmp)
}

/// Synthesize the emlBytes that main.swift would pass to `MailDriver.deliver`
/// for tests that don't otherwise care about the bytes. Uses the `ParsedMessage`
/// to fill in finalized recipients and a minimal HTML body when needed.
private func syntheticEml(for msg: ParsedMessage) -> Data {
    var headers = "Subject: \(msg.subject)\r\n"
    if !msg.to.isEmpty {
        headers += "To: " + msg.to.map { $0.address }.joined(separator: ", ") + "\r\n"
    }
    headers += "MIME-Version: 1.0\r\n"
    if let html = msg.htmlBody, !html.isEmpty {
        headers += "Content-Type: text/html; charset=utf-8\r\n\r\n"
        return Data((headers + html).utf8)
    } else {
        headers += "Content-Type: text/plain; charset=utf-8\r\n\r\n"
        return Data((headers + msg.body).utf8)
    }
}

let mailDriverTests = TestSuite(name: "MailDriver", cases: [
    TestCase(name: "draft_mode_emits_visible_true_and_no_send") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.subject = "Hello"
            msg.to = [ParsedAddress(displayName: "Alice", address: "alice@example.com")]
            msg.body = "Body."
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            try expectEqual(recorder.scripts.count, 1)
            try expect(script.contains("visible:true"))
            try expect(!script.contains("\n        send"), "draft must not emit send")
            try expect(script.contains("subject:\"Hello\""))
            try expect(script.contains("alice@example.com"))
            try expect(script.contains("name:\"Alice\""))
        }
    },

    TestCase(name: "send_mode_emits_visible_false_and_send_verb") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var opts = Options()
            opts.send = true
            var msg = ParsedMessage()
            msg.subject = "S"
            msg.to = [ParsedAddress(displayName: nil, address: "x@y")]
            msg.body = "b"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: opts, tmp: tmp, runner: recorder.run)
            try expect(script.contains("visible:false"))
            try expect(script.contains("\n        send"))
        }
    },

    TestCase(name: "sender_combined_from_F_and_f") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var opts = Options()
            opts.fromName = "Bot"
            opts.fromAddress = "bot@x.com"
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: opts, tmp: tmp, runner: recorder.run)
            try expect(script.contains("sender:\"Bot <bot@x.com>\""))
        }
    },

    TestCase(name: "sender_address_only") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var opts = Options()
            opts.fromAddress = "bare@x.com"
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: opts, tmp: tmp, runner: recorder.run)
            try expect(script.contains("sender:\"bare@x.com\""))
        }
    },

    TestCase(name: "cc_and_bcc_recipient_lines_emitted") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "a@x")]
            msg.cc = [ParsedAddress(displayName: nil, address: "b@y")]
            msg.bcc = [ParsedAddress(displayName: nil, address: "c@z")]
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            try expect(script.contains("make new to recipient at end of to recipients"))
            try expect(script.contains("make new cc recipient at end of cc recipients"))
            try expect(script.contains("make new bcc recipient at end of bcc recipients"))
            try expect(script.contains("address:\"a@x\""))
            try expect(script.contains("address:\"b@y\""))
            try expect(script.contains("address:\"c@z\""))
        }
    },

    TestCase(name: "attachment_makes_temp_file_and_references_it") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.attachments = [
                Attachment(filename: "note.txt", contentType: "text/plain", data: Data("hello\n".utf8))
            ]
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            try expect(script.contains("make new attachment with properties {file name:(POSIX file"))
            let contents = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
            let attFile = contents.first(where: { $0.hasPrefix("att-") })
            try expectNotNil(attFile)
            let attData = try Data(contentsOf: tmp.url.appendingPathComponent(attFile!))
            try expectEqual(attData, Data("hello\n".utf8))
        }
    },

    TestCase(name: "body_written_to_temp_file_with_quotes_and_backslashes") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.body = "Body with \"quotes\" and \\backslashes."
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            try expect(script.contains("body.txt"))
            let body = try String(contentsOf: tmp.url.appendingPathComponent("body.txt"), encoding: .utf8)
            try expectEqual(body, "Body with \"quotes\" and \\backslashes.")
        }
    },

    TestCase(name: "subject_with_special_chars_is_escaped") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.subject = "He said \"hi\" \\"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            try expect(script.contains("subject:\"He said \\\"hi\\\" \\\\\""))
        }
    },

    TestCase(name: "subject_with_line_separator_does_not_split_literal") {
        // AppleScript.quote must not pass U+2028 (LINE SEPARATOR) or U+2029
        // (PARAGRAPH SEPARATOR) through raw -- they could split the
        // double-quoted literal. They are mapped to an escaped \n.
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.subject = "before\u{2028}after\u{2029}end"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            try expect(!script.contains("\u{2028}"), "raw U+2028 must not appear in the emitted literal")
            try expect(!script.contains("\u{2029}"), "raw U+2029 must not appear in the emitted literal")
            try expect(script.contains("subject:\"before\\nafter\\nend\""))
        }
    },

    TestCase(name: "no_attachments_means_no_attachment_block") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            try expect(!script.contains("make new attachment"))
        }
    },

    TestCase(name: "runner_receives_well_formed_tell_block") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            try expect(script.hasPrefix("tell application \"Mail\""))
            try expect(script.hasSuffix("end tell"))
        }
    },

    // MARK: - Edit-draft path (HTML present)

    TestCase(name: "edit_draft_script_probes_accessibility_first") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.body = "plain fallback"
            msg.htmlBody = "<p>rich</p>"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            try expect(script.contains("get name of menu bar 1 of process \"Finder\""), "Accessibility probe must read UI of another process (the real gate)")
            try expect(script.contains("Accessibility permission required"))
            try expect(script.contains("if errNum is -1719 or errNum is 1002"))
        }
    },

    TestCase(name: "edit_draft_script_opens_eml_and_keystrokes_send_again") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.subject = "rich-html-subj"
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.htmlBody = "<p>rich</p>"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            try expect(script.contains("do shell script \"open -a Mail \" & quoted form of"))
            try expect(script.contains("compose-"))
            try expect(script.contains(".eml"))
            try expect(script.contains("keystroke \"d\" using {shift down, command down}"))
            // Windows are identified by id-diff, not by subject/title.
            try expect(script.contains("set beforeOpenIDs to id of every window"))
            try expect(script.contains("beforeOpenIDs does not contain (contents of wid)"))
            try expect(!script.contains("subjLine"), "must not match windows by subject anymore")
        }
    },

    TestCase(name: "edit_draft_poll_materializes_window_id_list_before_iterating") {
        // Regression: `repeat with wid in (id of every window)` keeps the id
        // list as a live Mail reference, so `item i of id of every window`
        // is sent back to Mail and fails with -1700 ("can't make ... into
        // type specifier"), aborting right after the .eml opens (the viewer
        // just sits there, never converted via Send Again). The poll must
        // assign the list to a plain variable first, then iterate that.
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.subject = "poll-coercion"
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.htmlBody = "<p>rich</p>"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            try expect(script.contains("set winIDs to id of every window"), "poll must materialize the id list to a variable")
            try expect(script.contains("repeat with wid in winIDs"), "poll must iterate the materialized list")
            try expect(!script.contains("repeat with wid in (id of every window)"), "must not iterate the live Mail reference (-1700)")
        }
    },

    TestCase(name: "edit_draft_script_writes_eml_with_html_body") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.subject = "x"
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.htmlBody = "<p>HTML payload</p>"
            _ = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            let emlFiles = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
                .filter { $0.hasSuffix(".eml") }
            try expectEqual(emlFiles.count, 1)
            let eml = try Data(contentsOf: tmp.url.appendingPathComponent(emlFiles[0]))
            let s = String(data: eml, encoding: .utf8) ?? ""
            try expect(s.contains("<p>HTML payload</p>"), "eml must contain the HTML body verbatim (pass-through)")
        }
    },

    TestCase(name: "edit_draft_path_carries_attachment_through_eml") {
        // A message with an HTML body AND an attachment routes to the
        // edit-draft path, which bypasses the classic `make new attachment`
        // code -- the attachment rides inside the raw .eml instead. Verified
        // live (2026-07-09): note7.txt arrived attached. This guards that the
        // .eml handed to Mail still carries the attachment part and that the
        // classic attach code is not emitted for HTML messages.
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.subject = "html-attach"
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.htmlBody = "<p>body</p>"
            msg.attachments = [
                Attachment(filename: "note7.txt", contentType: "text/plain", data: Data("hi\n".utf8))
            ]
            let emlText = "To: u@h\r\n"
                + "Subject: html-attach\r\n"
                + "MIME-Version: 1.0\r\n"
                + "Content-Type: multipart/mixed; boundary=\"B\"\r\n"
                + "\r\n"
                + "--B\r\n"
                + "Content-Type: text/html; charset=utf-8\r\n"
                + "\r\n"
                + "<p>body</p>\r\n"
                + "--B\r\n"
                + "Content-Type: text/plain; name=\"note7.txt\"\r\n"
                + "Content-Disposition: attachment; filename=\"note7.txt\"\r\n"
                + "\r\n"
                + "hi\r\n"
                + "--B--\r\n"
            let script = try MailDriver.deliver(msg, emlBytes: Data(emlText.utf8), options: Options(), tmp: tmp, runner: recorder.run)
            // Routes to edit-draft, not the classic attachment code.
            try expect(script.contains("keystroke \"d\" using {shift down, command down}"), "html+attachment must take the edit-draft path")
            try expect(!script.contains("make new attachment"), "classic attachment code is bypassed for HTML messages")
            // The attachment survives via the .eml pass-through.
            let emlFiles = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
                .filter { $0.hasSuffix(".eml") }
            try expectEqual(emlFiles.count, 1)
            let written = String(data: try Data(contentsOf: tmp.url.appendingPathComponent(emlFiles[0])), encoding: .utf8) ?? ""
            try expect(written.contains("Content-Disposition: attachment"), "attachment disposition must survive into the .eml")
            try expect(written.contains("filename=\"note7.txt\""), "the .eml handed to Mail must still carry the attachment part")
        }
    },

    TestCase(name: "edit_draft_script_clicks_message_send_when_send_flag") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var opts = Options()
            opts.send = true
            var msg = ParsedMessage()
            msg.subject = "rich-send"
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.htmlBody = "<p>rich</p>"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: opts, tmp: tmp, runner: recorder.run)
            try expect(script.contains("click menu item \"Send\" of menu \"Message\" of menu bar 1"))
        }
    },

    TestCase(name: "edit_draft_script_verifies_send_completed") {
        // #13: on the --send path the emitted script must verify the compose
        // window closed (id gone) after clicking Send, and error otherwise so
        // the binary exits non-zero rather than falsely reporting success.
        try withTempDir { tmp in
            let recorder = Recorder()
            var opts = Options()
            opts.send = true
            var msg = ParsedMessage()
            msg.subject = "verify-send"
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.htmlBody = "<p>rich</p>"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: opts, tmp: tmp, runner: recorder.run)
            // The Send click comes first...
            try expect(script.contains("click menu item \"Send\" of menu \"Message\" of menu bar 1"))
            // ...then a gone-poll on composeID that errors on timeout.
            try expect(script.contains("set composeIDGone to false"))
            try expect(script.contains("if currentIDs does not contain composeID then"))
            try expect(script.contains("if composeIDGone is false then error \"Send did not complete: the compose window is still open after 5s\""))
            // Ordering: verification must come after the Send click.
            let clickIdx = script.range(of: "click menu item \"Send\"")!.lowerBound
            let verifyIdx = script.range(of: "set composeIDGone to false")!.lowerBound
            try expect(clickIdx < verifyIdx, "verification must follow the Send click")
        }
    },

    TestCase(name: "edit_draft_script_no_send_verification_for_drafts") {
        // #13: the draft path must NOT emit the send-completion verification.
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.subject = "draft-no-verify"
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.htmlBody = "<p>rich</p>"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            try expect(!script.contains("composeIDGone"), "draft path must not verify a send that never happens")
        }
    },

    TestCase(name: "edit_draft_script_omits_send_click_for_drafts") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.subject = "rich-draft"
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.htmlBody = "<p>rich</p>"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            try expect(!script.contains("click menu item \"Send\""))
        }
    },

    TestCase(name: "edit_draft_script_closes_leftover_viewer") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.subject = "x"
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.htmlBody = "<p>x</p>"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            try expect(script.contains("close (first window whose id is viewerID) saving no"))
        }
    },

    TestCase(name: "edit_draft_script_matches_by_window_id_for_empty_subject") {
        // Regression: a message with no Subject must still identify the viewer
        // and compose windows. The old title-matching path set an empty
        // subjLine that never matched, so the poll timed out. Id-diffing has
        // no dependence on the subject at all.
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.subject = ""
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.htmlBody = "<p>no subject here</p>"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            try expect(script.contains("keystroke \"d\" using {shift down, command down}"), "empty-subject message must still reach the Send Again keystroke")
            try expect(script.contains("set beforeOpenIDs to id of every window"))
            try expect(script.contains("set beforeComposeIDs to id of every window"))
            try expect(!script.contains("subjLine"), "empty subject must not leak a subject-match gate")
            try expect(!script.contains("name of w"), "window identification must not depend on window title")
        }
    },

    TestCase(name: "edit_draft_path_skipped_when_html_body_is_whitespace_only") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.body = "plain"
            msg.htmlBody = "   \n\t  \n"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            try expect(!script.contains("keystroke \"d\""))
            try expect(script.contains("set content to (read"))
        }
    },

    TestCase(name: "edit_draft_script_uses_shared_poll_and_frontmost_helpers") {
        // #20: both window polls emit the same id-diff loop shape, and both
        // frontmost actions share the activate/delay/set-frontmost preamble.
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.subject = "helper-shape"
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.htmlBody = "<p>rich</p>"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            // Both polls present.
            try expect(script.contains("set viewerID to missing value"))
            try expect(script.contains("set composeID to missing value"))
            try expect(script.contains("beforeOpenIDs does not contain (contents of wid)"))
            try expect(script.contains("beforeComposeIDs does not contain (contents of wid)"))
            // Shared frontmost preamble appears for the keystroke: activate,
            // set frontmost, wait until actually frontmost, then act.
            try expect(script.contains("tell application \"Mail\" to activate"))
            try expect(script.contains("set frontmost to true"))
            try expect(script.contains("repeat until frontmost or (current date) > fdeadline"))
            try expect(script.contains("keystroke \"d\" using {shift down, command down}"))
            // Timeout messages preserved verbatim.
            try expect(script.contains("Mail did not open a viewer for the eml within 5s"))
            try expect(script.contains("Compose window did not appear after Send Again within 5s"))
        }
    },

    TestCase(name: "edit_draft_path_taken_for_email_output_wrapped_payload") {
        try withTempDir { tmp in
            let payload = """
            Subject: wrapped
            To: alice@example.com
            MIME-Version: 1.0
            Content-Type: multipart/mixed; boundary="OUTER"

            --OUTER
            Content-Type: multipart/alternative; boundary="INNER"

            --INNER
            Content-Type: text/plain; charset=utf-8

            plain

            --INNER
            Content-Type: text/html; charset=utf-8

            <html><body><p>hello</p></body></html>
            --INNER--
            --OUTER--
            """
            let raw = try RFC822Parser.parse(Data(payload.utf8))
            let msg = MIMEParser.parse(raw)
            let recorder = Recorder()
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            try expect(script.contains("keystroke \"d\""), "wrapper-with-html must take the edit-draft path")
        }
    },
])
