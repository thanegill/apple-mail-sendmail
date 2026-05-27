import Foundation
import SendmailCore

private final class Recorder {
    var scripts: [String] = []
    func run(_ source: String) throws { scripts.append(source) }
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
            try expect(script.contains("set subjLine to \"rich-html-subj\""))
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
            try expect(script.contains("close w saving no"))
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
