import Foundation
import SendmailCore

private final class Recorder {
    var scripts: [String] = []
    func run(_ source: String) throws { scripts.append(source) }
}

/// Throws on the first invocation, succeeds on subsequent ones. Lets us
/// simulate "rich-HTML path failed; classic fallback worked".
private final class FailOnceRecorder {
    var scripts: [String] = []
    var calls = 0
    struct Boom: Error {}
    func run(_ source: String) throws {
        calls += 1
        scripts.append(source)
        if calls == 1 { throw Boom() }
    }
}

private func withTempDir(_ body: (TempDir) throws -> Void) throws {
    let tmp = try TempDir()
    defer { tmp.cleanup() }
    try body(tmp)
}

/// True when `NSAttributedString.init(html:options:documentAttributes:)`
/// works in this environment. The Nix build sandbox does not have WebKit
/// linked, so HTML rendering returns nil there; we skip the affected tests
/// rather than failing them. Local `swift run sendmail-test` in `nix
/// develop` (or any non-sandbox environment) has WebKit and exercises the
/// real path.
private let webKitAvailable: Bool = {
    return MailDriver.renderHTMLToRTF(html: "<p>probe</p>", fontPrefs: .appleDefaults) != nil
}()

private func requireWebKit() throws {
    if !webKitAvailable {
        try skip("NSAttributedString HTML init unavailable (Nix sandbox without WebKit)")
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
            let script = try MailDriver.deliver(msg, options: Options(), tmp: tmp, runner: recorder.run)
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
            let script = try MailDriver.deliver(msg, options: opts, tmp: tmp, runner: recorder.run)
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
            let script = try MailDriver.deliver(msg, options: opts, tmp: tmp, runner: recorder.run)
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
            let script = try MailDriver.deliver(msg, options: opts, tmp: tmp, runner: recorder.run)
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
            let script = try MailDriver.deliver(msg, options: Options(), tmp: tmp, runner: recorder.run)
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
            let script = try MailDriver.deliver(msg, options: Options(), tmp: tmp, runner: recorder.run)
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
            let script = try MailDriver.deliver(msg, options: Options(), tmp: tmp, runner: recorder.run)
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
            let script = try MailDriver.deliver(msg, options: Options(), tmp: tmp, runner: recorder.run)
            try expect(script.contains("subject:\"He said \\\"hi\\\" \\\\\""))
        }
    },

    TestCase(name: "no_attachments_means_no_attachment_block") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            let script = try MailDriver.deliver(msg, options: Options(), tmp: tmp, runner: recorder.run)
            try expect(!script.contains("make new attachment"))
        }
    },

    TestCase(name: "runner_receives_well_formed_tell_block") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            let script = try MailDriver.deliver(msg, options: Options(), tmp: tmp, runner: recorder.run)
            try expect(script.hasPrefix("tell application \"Mail\""))
            try expect(script.hasSuffix("end tell"))
        }
    },

    TestCase(name: "rich_build_emits_rtf_read_and_set_content") {
        try requireWebKit()
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.body = "plain fallback"
            msg.htmlBody = "<p>rich</p>"
            let script = try MailDriver.deliver(msg, options: Options(), tmp: tmp, runner: recorder.run)
            try expectEqual(recorder.scripts.count, 1)
            try expect(script.contains("use scripting additions"), "rich-RTF script must declare scripting additions")
            try expect(script.contains("read POSIX file"), "must read RTF from disk")
            try expect(script.contains("as «class RTF »"), "must coerce read result to RTF class")
            try expect(script.contains("set content of newMessage to rtfData"), "must set content from RTF data")
            try expect(script.contains("make new outgoing message with properties"))
            try expect(!script.contains("NSSharingService"), "must not use NSSharingService")
            try expect(!script.contains("use framework"), "must not use the AppleScript-Cocoa framework bridge")
            try expect(!script.contains("make new paragraph at end with data"), "must not emit per-paragraph builders")
        }
    },

    TestCase(name: "rich_build_writes_rtf_temp_file") {
        try requireWebKit()
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.htmlBody = "<p>rich body</p>"
            _ = try MailDriver.deliver(msg, options: Options(), tmp: tmp, runner: recorder.run)
            let rtfURL = tmp.url.appendingPathComponent("body.rtf")
            let rtfBytes = try Data(contentsOf: rtfURL)
            try expect(rtfBytes.count > 0, "body.rtf must be non-empty")
            // First bytes of every RTF file are `{\\rtf`.
            let head = String(data: rtfBytes.prefix(5), encoding: .ascii) ?? ""
            try expect(head == "{\\rtf", "body.rtf must start with the RTF magic bytes, got: \(head)")
        }
    },

    TestCase(name: "rich_build_saves_and_restores_default_format") {
        try requireWebKit()
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.htmlBody = "<p>rich</p>"
            let script = try MailDriver.deliver(msg, options: Options(), tmp: tmp, runner: recorder.run)
            try expect(script.contains("set originalFormat to default message format"))
            try expect(script.contains("set default message format to rich format"))
            try expect(script.contains("if originalFormat is not rich format then"))
            try expect(script.contains("set default message format to originalFormat"))
            try expect(script.contains("on error"), "must restore default format in error path too")
        }
    },

    TestCase(name: "rich_build_path_handles_attachments") {
        try requireWebKit()
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.body = "plain"
            msg.htmlBody = "<p>rich</p>"
            msg.attachments = [
                Attachment(filename: "x.txt", contentType: "text/plain", data: Data("x".utf8))
            ]
            let script = try MailDriver.deliver(msg, options: Options(), tmp: tmp, runner: recorder.run)
            try expectEqual(recorder.scripts.count, 1)
            try expect(script.contains("set content of newMessage to rtfData"), "still rich-RTF path with attachments")
            try expect(script.contains("make new attachment with properties"))
            // attachment block must come AFTER the set content so the rich body is in place first.
            if let cIdx = script.range(of: "set content of newMessage to rtfData"),
               let aIdx = script.range(of: "make new attachment") {
                try expect(cIdx.lowerBound < aIdx.lowerBound, "set content must precede make new attachment")
            } else {
                try expect(false, "expected both set content and make new attachment in script")
            }
        }
    },

    TestCase(name: "rich_build_path_handles_send") {
        try requireWebKit()
        try withTempDir { tmp in
            let recorder = Recorder()
            var opts = Options()
            opts.send = true
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.body = "plain"
            msg.htmlBody = "<p>rich</p>"
            let script = try MailDriver.deliver(msg, options: opts, tmp: tmp, runner: recorder.run)
            try expect(script.contains("set content of newMessage to rtfData"), "still rich-RTF path in --send mode")
            try expect(script.contains("visible:false"))
            try expect(script.contains("tell newMessage to send"))
        }
    },

    TestCase(name: "rich_build_skipped_when_html_body_is_whitespace_only") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.body = "plain"
            msg.htmlBody = "   \n\t  \n"
            let script = try MailDriver.deliver(msg, options: Options(), tmp: tmp, runner: recorder.run)
            try expect(!script.contains("set content of newMessage to rtfData"), "whitespace-only HTML must not trigger rich path")
            try expect(script.contains("set content to (read"), "classic path uses read of body.txt as «class utf8»")
        }
    },

    TestCase(name: "rich_build_subject_and_recipients_are_quoted") {
        try requireWebKit()
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.subject = "She said \"hi\" \\ today"
            msg.to = [ParsedAddress(displayName: nil, address: "a@x")]
            msg.cc = [ParsedAddress(displayName: nil, address: "b@y")]
            msg.htmlBody = "<p>rich</p>"
            let script = try MailDriver.deliver(msg, options: Options(), tmp: tmp, runner: recorder.run)
            try expect(script.contains("subject:\"She said \\\"hi\\\" \\\\ today\""))
            try expect(script.contains("\"a@x\""))
            try expect(script.contains("\"b@y\""))
        }
    },

    TestCase(name: "rich_build_failure_falls_back_to_classic") {
        try requireWebKit()
        try withTempDir { tmp in
            let recorder = FailOnceRecorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.body = "plain fallback body"
            msg.htmlBody = "<p>rich</p>"
            let script = try MailDriver.deliver(msg, options: Options(), tmp: tmp, runner: recorder.run)
            try expect(recorder.calls == 2, "rich failure should trigger a classic fallback invocation")
            try expect(recorder.scripts[0].contains("set content of newMessage to rtfData"), "first attempt is rich-RTF")
            try expect(recorder.scripts[1].contains("set content to (read"), "second attempt is classic")
            try expect(script == recorder.scripts[1], "return value is the fallback script")
        }
    },

    TestCase(name: "rich_build_path_taken_for_email_output_wrapped_payload") {
        try requireWebKit()
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



            --INNER
            Content-Type: text/html; charset=utf-8

            <html><body><p>hello</p></body></html>
            --INNER--
            --OUTER--
            """
            let raw = try RFC822Parser.parse(Data(payload.utf8))
            let msg = MIMEParser.parse(raw)
            let recorder = Recorder()
            let script = try MailDriver.deliver(msg, options: Options(), tmp: tmp, runner: recorder.run)
            try expect(script.contains("set content of newMessage to rtfData"), "wrapper-without-attachments must take the rich path")
        }
    },

    TestCase(name: "render_html_to_rtf_substitutes_mail_fonts") {
        try requireWebKit()
        // Use real installed-on-macOS font names; NSFont(name:size:) returns
        // nil for unknown fonts and our substitution silently keeps the source
        // font in that case.
        let prefs = MailDriver.MailFontPrefs(
            messageFontName: "Verdana",
            messageFontSize: 14,
            fixedPitchFontName: "Monaco",
            fixedPitchFontSize: 9
        )
        let html = "<html><body><p>proportional para</p><pre>monospace para</pre></body></html>"
        guard let rtf = MailDriver.renderHTMLToRTF(html: html, fontPrefs: prefs) else {
            try expect(false, "renderHTMLToRTF returned nil")
            return
        }
        let rtfString = String(data: rtf, encoding: .ascii) ?? ""
        try expect(rtfString.contains("Verdana"), "messageFontName missing from RTF output: \(rtfString.prefix(200))")
        try expect(rtfString.contains("Monaco"), "fixedPitchFontName missing from RTF output: \(rtfString.prefix(200))")
        // The HTML's source defaults (Times-Roman / Courier) should be
        // replaced — confirm they don't appear.
        try expect(!rtfString.contains("Times-Roman"), "source proportional font leaked through substitution")
        try expect(!rtfString.contains("Courier"), "source monospace font leaked through substitution")
    },

    TestCase(name: "mail_font_prefs_apple_defaults_match_stock_mail") {
        let p = MailDriver.MailFontPrefs.appleDefaults
        try expectEqual(p.messageFontName, "Helvetica")
        try expectEqual(p.messageFontSize, 12)
        try expectEqual(p.fixedPitchFontName, "Menlo-Regular")
        try expectEqual(p.fixedPitchFontSize, 11)
    },
])
