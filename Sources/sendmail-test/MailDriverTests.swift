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

    TestCase(name: "rich_build_emits_dictionary_paragraph_makers") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.body = "plain fallback"
            msg.htmlBody = "<p>rich</p>"
            let script = try MailDriver.deliver(msg, options: Options(), tmp: tmp, runner: recorder.run)
            try expectEqual(recorder.scripts.count, 1)
            try expect(script.contains("tell application \"Mail\""))
            try expect(script.contains("make new outgoing message with properties"))
            try expect(script.contains("tell content"))
            try expect(script.contains("make new paragraph at end with data"))
            try expect(!script.contains("NSSharingService"), "must not use NSSharingService anymore")
            try expect(!script.contains("use framework"), "no AppleScript-Cocoa bridge in the new path")
        }
    },

    TestCase(name: "rich_build_path_handles_attachments") {
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
            try expect(script.contains("make new paragraph at end with data"), "still rich path with attachments")
            try expect(script.contains("make new attachment with properties"))
            // attachment block must come after the paragraphs (within `tell content`)
            if let pIdx = script.range(of: "make new paragraph"),
               let aIdx = script.range(of: "make new attachment") {
                try expect(pIdx.lowerBound < aIdx.lowerBound, "paragraphs must be emitted before attachments")
            } else {
                try expect(false, "expected both paragraph and attachment in script")
            }
        }
    },

    TestCase(name: "rich_build_path_handles_send") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var opts = Options()
            opts.send = true
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.body = "plain"
            msg.htmlBody = "<p>rich</p>"
            let script = try MailDriver.deliver(msg, options: opts, tmp: tmp, runner: recorder.run)
            try expect(script.contains("make new paragraph at end with data"), "still rich path in --send mode")
            try expect(script.contains("visible:false"))
            try expect(script.contains("\n        send"))
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
            try expect(!script.contains("make new paragraph at end with data"), "whitespace-only HTML must not trigger rich path")
            try expect(script.contains("set content to (read"), "classic path uses read of body.txt")
        }
    },

    TestCase(name: "rich_build_subject_and_recipients_are_quoted") {
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
        try withTempDir { tmp in
            let recorder = FailOnceRecorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.body = "plain fallback body"
            msg.htmlBody = "<p>rich</p>"
            let script = try MailDriver.deliver(msg, options: Options(), tmp: tmp, runner: recorder.run)
            try expect(recorder.calls == 2, "rich failure should trigger a classic fallback invocation")
            try expect(recorder.scripts[0].contains("make new paragraph at end with data"), "first attempt is rich-build")
            try expect(recorder.scripts[1].contains("set content to (read"), "second attempt is classic")
            try expect(script == recorder.scripts[1], "return value is the fallback script")
        }
    },

    TestCase(name: "rich_build_path_taken_for_email_output_wrapped_payload") {
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
            try expect(script.contains("make new paragraph at end with data"), "wrapper-without-attachments must take the rich path")
        }
    },

    TestCase(name: "rich_build_paragraph_with_font_size_color") {
        try withTempDir { tmp in
            let recorder = Recorder()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.htmlBody = "<html><head><style>pre { color: red; }</style></head><body><pre>mono</pre></body></html>"
            let script = try MailDriver.deliver(msg, options: Options(), tmp: tmp, runner: recorder.run)
            // The <pre> paragraph should emit with a font and color in its properties record.
            try expect(script.contains("with properties {"), "paragraph properties record must be present")
            try expect(script.contains("font:\""), "paragraph must carry a font name")
            // size is a number with no quotes
            try expect(script.range(of: #"size:\d"#, options: .regularExpression) != nil, "paragraph must carry a size number")
        }
    },
])
