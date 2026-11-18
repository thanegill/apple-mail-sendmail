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

/// Substring search over unicode scalars, so a needle that starts or ends
/// inside a grapheme cluster of the haystack still matches exactly.
private func scalarsContain(_ haystack: String, _ needle: String) -> Bool {
    let hayScalars = Array(haystack.unicodeScalars)
    let needleScalars = Array(needle.unicodeScalars)
    guard !needleScalars.isEmpty, needleScalars.count <= hayScalars.count else { return needleScalars.isEmpty }
    for start in 0...(hayScalars.count - needleScalars.count)
    where hayScalars[start..<(start + needleScalars.count)].elementsEqual(needleScalars) {
        return true
    }
    return false
}

/// Run a plain-text message with the given raw `From:` value through the
/// real parsers and the classic path, returning the emitted script.
private func classicScript(fromHeader: String, tmp: TempDir) throws -> String {
    let input = "From: \(fromHeader)\nTo: u@example.test\nSubject: s\nContent-Type: text/plain\n\nbody\n"
    let raw = try RFC822Parser.parse(Data(input.utf8))
    let msg = MIMEParser.parse(raw)
    let recorder = Recorder()
    return try MailDriver.deliver(msg, emlBytes: Data(input.utf8), options: Options(), tmp: tmp, runner: recorder.run)
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

    TestCase(name: "sender_f_without_domain_passed_through") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var opts = Options()
            opts.fromAddress = "root"
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@example.test")]
            msg.body = "b"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: opts, tmp: tmp, runner: recorder.run)
            try expect(script.contains("sender:\"root\""), "the header-From domain check must not filter an explicit -f")
        }
    },

    TestCase(name: "sender_from_header_when_no_f") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.from = ParsedAddress(displayName: nil, address: "work@example.test")
            msg.to = [ParsedAddress(displayName: nil, address: "u@example.test")]
            msg.body = "b"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run)
            try expect(script.contains("sender:\"work@example.test\""), "header From must select the account")
        }
    },

    TestCase(name: "sender_f_overrides_header_from") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var opts = Options()
            opts.fromAddress = "cli@example.test"
            var msg = ParsedMessage()
            msg.from = ParsedAddress(displayName: "Work Bot", address: "work@example.test")
            msg.to = [ParsedAddress(displayName: nil, address: "u@example.test")]
            msg.body = "b"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: opts, tmp: tmp, runner: recorder.run)
            try expect(script.contains("sender:\"cli@example.test\""))
            try expect(!script.contains("work@example.test"), "-f must fully replace the header From, display name included")
        }
    },

    TestCase(name: "sender_F_without_f_keeps_header_from") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var opts = Options()
            opts.fromName = "Ignored Name"
            var msg = ParsedMessage()
            msg.from = ParsedAddress(displayName: "Work Bot", address: "work@example.test")
            msg.to = [ParsedAddress(displayName: nil, address: "u@example.test")]
            msg.body = "b"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: opts, tmp: tmp, runner: recorder.run)
            try expect(script.contains("sender:\"Work Bot <work@example.test>\""))
            try expect(!script.contains("Ignored Name"))
        }
    },

    TestCase(name: "sender_omitted_without_f_or_header_from") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var opts = Options()
            opts.fromName = "Ignored Name"
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@example.test")]
            msg.body = "b"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: opts, tmp: tmp, runner: recorder.run)
            try expect(!script.contains("sender:"))
        }
    },

    TestCase(name: "sender_omitted_for_cron_daemon_header_from") {
        try withTempDir { tmp in
            let script = try classicScript(fromHeader: "root (Cron Daemon)", tmp: tmp)
            try expect(!script.contains("sender:"), "a local-only cron From must leave Mail on its default account")
        }
    },

    TestCase(name: "sender_omitted_for_bare_local_header_from") {
        try withTempDir { tmp in
            let script = try classicScript(fromHeader: "root", tmp: tmp)
            try expect(!script.contains("sender:"))
        }
    },

    TestCase(name: "sender_omitted_for_empty_group_header_from") {
        try withTempDir { tmp in
            let script = try classicScript(fromHeader: "undisclosed-recipients:;", tmp: tmp)
            try expect(!script.contains("sender:"))
        }
    },

    TestCase(name: "sender_from_parsed_header_with_encoded_display_name") {
        try withTempDir { tmp in
            let input = """
            From: =?UTF-8?B?QsO8cm8gQm90?= <work@example.test>
            To: u@example.test
            Subject: cron
            Content-Type: text/plain; charset=utf-8

            plain body
            """
            let raw = try RFC822Parser.parse(Data(input.utf8))
            let msg = MIMEParser.parse(raw)
            let recorder = Recorder()
            let script = try MailDriver.deliver(msg, emlBytes: Data(input.utf8), options: Options(), tmp: tmp, runner: recorder.run)
            try expect(script.contains("sender:\"Büro Bot <work@example.test>\""))
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

    TestCase(name: "quote_escapes_crlf_grapheme_cluster") {
        // Swift fuses "\r\n" into one Character, which matches neither the
        // "\r" nor the "\n" case of a Character-level switch.
        let quoted = AppleScript.quote("a\r\nb")
        try expectEqual(quoted, "\"a\\r\\nb\"")
        try expect(!quoted.unicodeScalars.contains("\r"), "raw CR must not appear in the literal")
        try expect(!quoted.unicodeScalars.contains("\n"), "raw LF must not appear in the literal")
    },

    TestCase(name: "quote_maps_control_with_combining_mark_to_space") {
        // The combining mark must survive while the control before it is
        // still escaped or mapped to a space.
        let quoted = AppleScript.quote("a\u{01}\u{0301}b\r\u{0301}c")
        try expectEqual(quoted, "\"a \u{0301}b\\r\u{0301}c\"")
        try expect(!quoted.unicodeScalars.contains { $0.value < 0x20 }, "no raw C0 control may appear in the literal")
    },

    TestCase(name: "quote_existing_escapes_unchanged") {
        try expectEqual(AppleScript.quote(""), "\"\"")
        try expectEqual(AppleScript.quote("plain ASCII 123"), "\"plain ASCII 123\"")
        try expectEqual(AppleScript.quote("q\"b\\"), "\"q\\\"b\\\\\"")
        try expectEqual(AppleScript.quote("n\nr\rt\t"), "\"n\\nr\\rt\\t\"")
        try expectEqual(AppleScript.quote("ls\u{2028}ps\u{2029}"), "\"ls\\nps\\n\"")
        try expectEqual(AppleScript.quote("nul\u{00}esc\u{1B}us\u{1F}"), "\"nul esc us \"")
        try expectEqual(AppleScript.quote("del\u{7F}"), "\"del\u{7F}\"")
        try expectEqual(AppleScript.quote("caf\u{E9} e\u{0301} \u{1F600} \u{1F1FA}\u{1F1F8}"), "\"caf\u{E9} e\u{0301} \u{1F600} \u{1F1FA}\u{1F1F8}\"")
    },

    // A `"` or `\` that shares a grapheme cluster with a neighbour (GB9,
    // GB9a, GB9b) is not a bare "\"" Character, so a Character-level switch
    // passed it through unescaped and it could end the literal.
    TestCase(name: "quote_escapes_quote_followed_by_combining_mark") {
        try expectEqual(AppleScript.quote("\"\u{0301}"), "\"\\\"\u{0301}\"")
    },

    TestCase(name: "quote_escapes_quote_preceded_by_prepend") {
        try expectEqual(AppleScript.quote("\u{0600}\""), "\"\u{0600}\\\"\"")
    },

    TestCase(name: "quote_escapes_backslash_followed_by_combining_mark") {
        try expectEqual(AppleScript.quote("\\\u{0301}"), "\"\\\\\u{0301}\"")
    },

    TestCase(name: "encoded_subject_cannot_inject_applescript") {
        let payload = "X\u{0600}\" & (count {1, 2, 3}) & (character id {80, 87, 78}) & \"\u{0301}"
        let encoded = "=?UTF-8?B?" + Data(payload.utf8).base64EncodedString() + "?="
        let eml = Data("To: u@h\r\nSubject: \(encoded)\r\n\r\nbody\r\n".utf8)
        let msg = MIMEParser.parse(try RFC822Parser.parse(eml))
        try expectEqual(msg.subject, payload)
        try withTempDir { tmp in
            let recorder = Recorder()
            let script = try MailDriver.deliver(msg, emlBytes: eml, options: Options(), tmp: tmp, runner: recorder.run)
            let escapedLiteral = "subject:\"X\u{0600}\\\" & (count {1, 2, 3}) & (character id {80, 87, 78}) & \\\"\u{0301}\""
            try expect(scalarsContain(script, escapedLiteral), "subject must be emitted as one escaped literal")
            try expect(!scalarsContain(script, "\u{0600}\" & (count"), "unescaped quote would end the literal and run the injected expression")
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

    // MARK: - HTML path routing
    //
    // The HTML path's own steps are covered by the AXHTMLDelivery suite;
    // these check what MailDriver hands it.

    TestCase(name: "html_message_hands_its_eml_to_the_html_path_and_runs_no_applescript") {
        try withTempDir { tmp in
            let recorder = Recorder()
            let html = RecordingHTMLDelivery()
            var msg = ParsedMessage()
            msg.subject = "rich-html-subj"
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.htmlBody = "<p>rich</p>"
            try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run, html: html)
            try expect(recorder.scripts.isEmpty, "an HTML message must not run AppleScript")
            try expectEqual(html.calls.count, 1)
            let url = html.calls[0].url
            try expect(url.lastPathComponent.hasPrefix("compose-") && url.pathExtension == "eml", "unexpected eml name \(url.lastPathComponent)")
            try expectEqual(url.deletingLastPathComponent().path, tmp.url.path)
            try expect(html.calls[0].emlExisted, "the eml must exist when the HTML path runs")
        }
    },

    TestCase(name: "html_path_gets_the_send_flag") {
        for send in [false, true] {
            try withTempDir { tmp in
                let html = RecordingHTMLDelivery()
                var opts = Options()
                opts.send = send
                var msg = ParsedMessage()
                msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
                msg.htmlBody = "<p>rich</p>"
                try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: opts, tmp: tmp, runner: Recorder().run, html: html)
                try expectEqual(html.calls.map(\.send), [send])
            }
        }
    },

    TestCase(name: "html_path_writes_eml_with_html_body") {
        try withTempDir { tmp in
            var msg = ParsedMessage()
            msg.subject = "x"
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.htmlBody = "<p>HTML payload</p>"
            try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: Recorder().run)
            let emlFiles = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
                .filter { $0.hasSuffix(".eml") }
            try expectEqual(emlFiles.count, 1)
            let eml = try Data(contentsOf: tmp.url.appendingPathComponent(emlFiles[0]))
            let s = String(data: eml, encoding: .utf8) ?? ""
            try expect(s.contains("<p>HTML payload</p>"), "eml must contain the HTML body verbatim (pass-through)")
        }
    },

    TestCase(name: "html_path_carries_attachment_through_eml") {
        // A message with an HTML body AND an attachment routes to the HTML
        // path, which bypasses the classic `make new attachment` code -- the
        // attachment rides inside the raw .eml instead. Verified live
        // (2026-07-09): note7.txt arrived attached. This guards that the .eml
        // handed to Mail still carries the attachment part and that the
        // classic attach code does not run for HTML messages.
        try withTempDir { tmp in
            let recorder = Recorder()
            let html = RecordingHTMLDelivery()
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
            try MailDriver.deliver(msg, emlBytes: Data(emlText.utf8), options: Options(), tmp: tmp, runner: recorder.run, html: html)
            try expectEqual(html.calls.count, 1)
            try expect(recorder.scripts.isEmpty, "classic attachment code is bypassed for HTML messages")
            let files = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
            try expect(!files.contains { $0.hasPrefix("att-") }, "HTML messages stage no attachment files")
            let written = String(data: try Data(contentsOf: html.calls[0].url), encoding: .utf8) ?? ""
            try expect(written.contains("Content-Disposition: attachment"), "attachment disposition must survive into the .eml")
            try expect(written.contains("filename=\"note7.txt\""), "the .eml handed to Mail must still carry the attachment part")
        }
    },

    TestCase(name: "html_path_skipped_when_html_body_is_whitespace_only") {
        try withTempDir { tmp in
            let recorder = Recorder()
            let html = RecordingHTMLDelivery()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.body = "plain"
            msg.htmlBody = "   \n\t  \n"
            let script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: recorder.run, html: html)
            try expect(html.calls.isEmpty)
            try expect(script.contains("set content to (read"))
        }
    },

    TestCase(name: "html_path_taken_for_email_output_wrapped_payload") {
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
            let html = RecordingHTMLDelivery()
            try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, runner: Recorder().run, html: html)
            try expect(html.calls.count == 1, "wrapper-with-html must take the HTML path")
        }
    },

    TestCase(name: "deliver_then_clean_up_removes_tmp_after_html_success") {
        let tmp = try TempDir()
        defer { tmp.cleanup() }
        var filesSeenByDelivery: [String] = []
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "rcpt@example.test")]
        msg.htmlBody = "<p>hi</p>"
        let html = RecordingHTMLDelivery()
        html.onDeliver = { _ in
            filesSeenByDelivery = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
        }
        let automation = MailAutomation(plain: AppleScriptPlainDelivery(staging: tmp, runner: Recorder().run), html: html)
        try MailDriver.deliverThenCleanUp(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, automation: automation)
        try expect(filesSeenByDelivery.contains { $0.hasSuffix(".eml") }, "eml must exist while the HTML path runs")
        try expect(!FileManager.default.fileExists(atPath: tmp.url.path), "temp dir left behind after success")
    },

    TestCase(name: "deliver_then_clean_up_removes_tmp_after_classic_success") {
        let tmp = try TempDir()
        defer { tmp.cleanup() }
        var filesSeenByRunner: [String] = []
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "rcpt@example.test")]
        msg.body = "plain"
        msg.attachments = [
            Attachment(filename: "note.txt", contentType: "text/plain", data: Data("hello\n".utf8))
        ]
        let plain = AppleScriptPlainDelivery(staging: tmp) { _ in
            filesSeenByRunner = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
        }
        let automation = MailAutomation(plain: plain, html: RecordingHTMLDelivery())
        try MailDriver.deliverThenCleanUp(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, automation: automation)
        try expect(filesSeenByRunner.contains("body.txt"), "body must exist while the script runs")
        try expect(filesSeenByRunner.contains { $0.hasPrefix("att-") }, "attachment must exist while the script runs")
        try expect(!FileManager.default.fileExists(atPath: tmp.url.path), "temp dir left behind after success")
    },

    TestCase(name: "deliver_then_clean_up_removes_tmp_when_delivery_throws") {
        let tmp = try TempDir()
        defer { tmp.cleanup() }
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "rcpt@example.test")]
        msg.body = "plain"
        let plain = AppleScriptPlainDelivery(staging: tmp) { _ in
            throw AppleScript.Failure(code: -1743, message: "denied")
        }
        var thrown: Error?
        do {
            try MailDriver.deliverThenCleanUp(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, automation: MailAutomation(plain: plain, html: RecordingHTMLDelivery()))
        } catch {
            thrown = error
        }
        try expectEqual((thrown as? AppleScript.Failure)?.code, -1743)
        try expect(!FileManager.default.fileExists(atPath: tmp.url.path), "temp dir left behind after a delivery failure")
    },
])
