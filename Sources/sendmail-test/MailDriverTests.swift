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

    TestCase(name: "edit_draft_script_opens_eml_and_clicks_send_again") {
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
            try expect(script.contains(sendAgainClick))
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
            try expect(script.contains(sendAgainClick), "html+attachment must take the edit-draft path")
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
            // ...then a gone-poll on composeID, and an error if every
            // attempt left the compose open.
            try expect(script.contains("if currentIDs does not contain composeID then"))
            try expect(script.contains("\nif composeIDGone is false then error \"Send did not complete: the compose window is still open after 3 Send menu clicks\""))
            // Ordering: a gone-poll must follow the Send click.
            let clickIdx = script.range(of: "click menu item \"Send\"")!.lowerBound
            let pollAfterClick = script[clickIdx...].range(of: "if currentIDs does not contain composeID then")
            try expect(pollAfterClick != nil, "verification must follow the Send click")
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
            try expect(script.contains(sendAgainClick), "empty-subject message must still reach the Send Again click")
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
            try expect(!script.contains("Send Again"))
            try expect(script.contains("set content to (read"))
        }
    },

    TestCase(name: "edit_draft_script_uses_shared_poll_and_verified_front_window_helpers") {
        // #20: both window polls emit the same id-diff loop shape, and the
        // Send Again click goes through the shared activate/raise/verify helper.
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
            // Shared focus preamble appears for the Send Again click: activate,
            // set frontmost, raise the target window, verify, then act.
            try expect(script.contains("tell application \"Mail\" to activate"))
            try expect(script.contains("tell application \"System Events\" to set frontmost of process \"Mail\" to true"))
            try expect(script.contains("repeat until viewerIDActed or (current date) > fdeadline"))
            try expect(script.contains(sendAgainClick))
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
            try expect(script.contains(sendAgainClick), "wrapper-with-html must take the edit-draft path")
        }
    },

    TestCase(name: "deliver_then_clean_up_removes_tmp_after_html_success") {
        let tmp = try TempDir()
        defer { tmp.cleanup() }
        var filesSeenByRunner: [String] = []
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "rcpt@example.test")]
        msg.htmlBody = "<p>hi</p>"
        try MailDriver.deliverThenCleanUp(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp) { _ in
            filesSeenByRunner = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
        }
        try expect(filesSeenByRunner.contains { $0.hasSuffix(".eml") }, "eml must exist while the script runs")
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
        try MailDriver.deliverThenCleanUp(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp) { _ in
            filesSeenByRunner = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
        }
        try expect(filesSeenByRunner.contains("body.txt"), "body must exist while the script runs")
        try expect(filesSeenByRunner.contains { $0.hasPrefix("att-") }, "attachment must exist while the script runs")
        try expect(!FileManager.default.fileExists(atPath: tmp.url.path), "temp dir left behind after success")
    },

    TestCase(name: "deliver_then_clean_up_removes_tmp_when_runner_throws") {
        let tmp = try TempDir()
        defer { tmp.cleanup() }
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "rcpt@example.test")]
        msg.body = "plain"
        var thrown: Error?
        do {
            try MailDriver.deliverThenCleanUp(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp) { _ in
                throw AppleScript.Failure(code: -1743, message: "denied")
            }
        } catch {
            thrown = error
        }
        try expectEqual((thrown as? AppleScript.Failure)?.code, -1743)
        try expect(!FileManager.default.fileExists(atPath: tmp.url.path), "temp dir left behind after runner failure")
    },

    // MARK: - Edit-draft key-window verification
    //
    // Mail's menu commands act on its key window. Send Again on a viewer is
    // Send on a compose, so the target is raised and verified front, main
    // and key in the same `tell process "Mail"` block as each menu click,
    // and a timeout errors instead of acting.

    TestCase(name: "edit_draft_raises_and_verifies_viewer_before_send_again_click") {
        let script = try emitEditDraftScript(send: false)
        let raiseIdx = try offset(of: "tell application \"Mail\" to set index of (first window whose id is viewerID) to 1", in: script)
        let frontWindowReadIdx = try offset(of: "set frontWindowID to id of window 1", in: script)
        let frontCheckIdx = try offset(of: "else if frontWindowID is not viewerID then", in: script)
        let keyIsMainIdx = try offset(of: "if value of attribute \"AXMain\" of keyWindow is not true then", in: script)
        let sendAgainIdx = try offset(of: sendAgainClick, in: script)
        try expect(raiseIdx < frontWindowReadIdx, "viewer must be raised before its checks")
        try expect(frontWindowReadIdx < frontCheckIdx, "front window id must be read before comparing it to viewerID")
        try expect(frontCheckIdx < keyIsMainIdx, "the front check precedes the key == main check")
        try expect(keyIsMainIdx < sendAgainIdx, "viewer must be verified key before the Send Again click")
    },

    TestCase(name: "edit_draft_scripts_send_no_keystrokes") {
        // A keystroke goes to whichever app is frontmost; a menu click on
        // process "Mail" can only reach Mail.
        for send in [false, true] {
            let script = try emitEditDraftScript(send: send)
            try expect(!script.contains("keystroke"), "send=\(send): edit-draft script must not send keystrokes")
            try expect(!script.contains("key code"), "send=\(send): edit-draft script must not send key codes")
            let lines = script.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            try expectEqual(lines.filter { $0 == sendAgainClick }.count, 1)
        }
    },

    TestCase(name: "edit_draft_verifies_compose_window_before_send_click") {
        let script = try emitEditDraftScript(send: true)
        let composePollIdx = try offset(of: "set composeID to missing value", in: script)
        let raiseIdx = try offset(of: "tell application \"Mail\" to set index of (first window whose id is composeID) to 1", in: script)
        let frontCheckIdx = try offset(of: "else if frontWindowID is not composeID then", in: script)
        let clickIdx = try offset(of: "click menu item \"Send\" of menu \"Message\" of menu bar 1", in: script)
        let keyIsMainIdx = script[frontCheckIdx...].range(of: "if value of attribute \"AXMain\" of keyWindow is not true then")?.lowerBound
        try expectNotNil(keyIsMainIdx)
        try expect(composePollIdx < raiseIdx, "compose must be identified before it is raised")
        try expect(raiseIdx < frontCheckIdx, "compose must be raised before its checks")
        try expect(keyIsMainIdx! < clickIdx, "compose must be verified key before the Send click")
    },

    TestCase(name: "edit_draft_key_window_timeout_errors_instead_of_acting") {
        let script = try emitEditDraftScript(send: true)
        try expect(!script.contains("repeat until frontmost or"), "a frontmost wait that falls through on timeout must not remain")
        let lines = trimmedLines(script)
        let expectedErrors = [
            "viewerID": "if not viewerIDActed then error \"The eml viewer window did not pass the key-window check within 3s; the Send Again menu click was not sent. Last failed check: \" & viewerIDFailedCheck",
            "composeID": "if not composeIDActed then error \"The compose window did not pass the key-window check within 3s; the Send menu click was not sent. Last failed check: \" & composeIDFailedCheck",
        ]
        for windowVar in frontWindowVars {
            let loopStart = try expectLineIndex(lines, "repeat until \(windowVar)Acted or (current date) > fdeadline")
            let loopEnd = try expectLineIndex(lines, "end repeat", after: loopStart)
            try expectEqual(lines[loopEnd + 1], expectedErrors[windowVar]!)
        }
    },

    TestCase(name: "edit_draft_acted_flag_starts_false_and_is_set_only_after_the_guarded_action") {
        // Guards against a silent fall-through: an acted flag initialised to
        // true, or set true outside the guarded branch, ends the loop without
        // the check and hides the timeout error.
        let script = try emitEditDraftScript(send: true)
        let lines = trimmedLines(script)
        for windowVar in frontWindowVars {
            let actedVar = "\(windowVar)Acted"
            let loopStart = try expectLineIndex(lines, "repeat until \(actedVar) or (current date) > fdeadline")
            let initIdx = try expectLineIndex(lines, "set \(actedVar) to false")
            try expect(initIdx < loopStart, "\(actedVar) must be initialised to false before its loop")
            let assignmentIndexes = lines.indices.filter { lines[$0].contains("set \(actedVar) to") }
            try expectEqual(assignmentIndexes.count, 2)
            let setTrueIndexes = lines.indices.filter {
                lines[$0].trimmingCharacters(in: .whitespaces) == "set \(actedVar) to true"
            }
            try expectEqual(setTrueIndexes.count, 1)
            let setTrueIdx = setTrueIndexes[0]
            try expect(isUIActionLine(lines[setTrueIdx - 1]), "\(actedVar) must be set directly after the action, got: \(lines[setTrueIdx - 1])")
            try expectEqual(lines[setTrueIdx - 2].trimmingCharacters(in: .whitespaces), "if \(windowVar)FailedCheck is \"\" then")
            try expect(Set(assignmentIndexes) == Set([initIdx, setTrueIdx]), "\(actedVar) may only be assigned by its false init and after the guarded action")
        }
    },

    TestCase(name: "edit_draft_window_lookups_error_clearly_when_target_window_closes") {
        let script = try emitEditDraftScript(send: true)
        let lines = script.components(separatedBy: "\n")
        let windowNames = ["viewerID": "eml viewer", "composeID": "compose"]
        for windowVar in frontWindowVars {
            let closedPrefix = "error \"The \(windowNames[windowVar]!) window (id \" & \(windowVar) & \") closed before "
            let closedErrorIndexes = lines.indices.filter {
                lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix(closedPrefix)
            }
            // The initial raise, the per-attempt Mail reads, and the re-raise.
            try expectEqual(closedErrorIndexes.count, 3)
            var protectedLines: [String] = []
            for errorIdx in closedErrorIndexes {
                try expect(lines[errorIdx].hasSuffix("errMsg number errNum"))
                try expectEqual(lines[errorIdx - 1].trimmingCharacters(in: .whitespaces), "on error errMsg number errNum")
                try expectEqual(lines[errorIdx + 1].trimmingCharacters(in: .whitespaces), "end try")
                let tryIdx = lines[..<errorIdx].lastIndex { $0.trimmingCharacters(in: .whitespaces) == "try" }!
                protectedLines += lines[(tryIdx + 1)..<(errorIdx - 1)].map { $0.trimmingCharacters(in: .whitespaces) }
            }
            let raiseLine = "tell application \"Mail\" to set index of (first window whose id is \(windowVar)) to 1"
            try expectEqual(protectedLines.filter { $0 == raiseLine }.count, 2)
            try expect(protectedLines.contains("set frontWindowID to id of window 1"))
            try expect(protectedLines.contains("set targetName to name of (first window whose id is \(windowVar))"))
        }
        let closeCount = script.components(separatedBy: "close (first window whose id is viewerID)").count - 1
        try expectEqual(closeCount, 1)
    },

    TestCase(name: "edit_draft_every_ui_action_follows_the_full_key_window_guard") {
        for send in [false, true] {
            let script = try emitEditDraftScript(send: send)
            let lines = script.components(separatedBy: "\n")
            let actionLineIndexes = lines.indices.filter { isUIActionLine(lines[$0]) }
            try expectEqual(actionLineIndexes.count, send ? 2 : 1)
            for actionIdx in actionLineIndexes {
                let guardLine = lines[actionIdx - 1].trimmingCharacters(in: .whitespaces)
                let guardPrefix = "if "
                let guardSuffix = "FailedCheck is \"\" then"
                try expect(
                    guardLine.hasPrefix(guardPrefix) && guardLine.hasSuffix(guardSuffix),
                    "line \(actionIdx + 1) (\(lines[actionIdx])) must directly follow the key-window guard, got: \(guardLine)"
                )
                let windowVar = String(guardLine.dropFirst(guardPrefix.count).dropLast(guardSuffix.count))
                let processTellIdx = try expectNotNilValue(
                    lines[..<actionIdx].lastIndex { $0.trimmingCharacters(in: .whitespaces) == "tell process \"Mail\"" },
                    "action at line \(actionIdx + 1) must be inside a tell process \"Mail\" block"
                )
                try expectEqual(lines[processTellIdx - 1].trimmingCharacters(in: .whitespaces), "tell application \"System Events\"")
                let block = lines[(processTellIdx + 1)..<actionIdx].map { $0.trimmingCharacters(in: .whitespaces) }
                try expect(!block.contains { $0.hasPrefix("delay") }, "no delay between the checks and the action")
                let blockTellsOpened = block.filter { $0.hasPrefix("tell ") && !$0.contains(" to ") }.count
                let blockTellsClosed = block.filter { $0 == "end tell" }.count
                try expect(blockTellsClosed <= blockTellsOpened, "the checks and the action must share one tell process \"Mail\" block")
                let failedCheckVar = "\(windowVar)FailedCheck"
                let requiredInOrder = [
                    "set frontWindowID to id of window 1",
                    "set targetName to name of (first window whose id is \(windowVar))",
                    "set \(failedCheckVar) to \"\"",
                    "if not frontmost then",
                    "else if frontWindowID is not \(windowVar) then",
                    "set keyWindow to value of attribute \"AXFocusedWindow\"",
                    "set mainWindow to value of attribute \"AXMainWindow\"",
                    "if value of attribute \"AXMain\" of keyWindow is not true then",
                    "else if value of attribute \"AXSubrole\" of mainWindow is not \"AXStandardWindow\" then",
                    "else if (count of sheets of mainWindow) is not 0 then",
                    "else if value of attribute \"AXTitle\" of mainWindow is not targetName then",
                    "on error errMsg",
                    "set \(failedCheckVar) to \"Mail's accessibility attributes could not be read: \" & errMsg",
                ]
                let clearLine = "set \(failedCheckVar) to \"\""
                let clearCount = lines.filter { $0.trimmingCharacters(in: .whitespaces) == clearLine }.count
                try expectEqual(clearCount, 1)
                var searchFrom = 0
                for required in requiredInOrder {
                    guard let found = block[searchFrom...].firstIndex(of: required) else {
                        throw TestFailure(message: "guard for line \(actionIdx + 1) is missing, or has out of order: \(required)", file: #file, line: #line)
                    }
                    searchFrom = found + 1
                }
                // Every failing branch records a non-empty reason.
                for (offsetInBlock, line) in block.enumerated() where line.hasPrefix("if ") || line.hasPrefix("else if ") {
                    guard line != guardLine else { continue }
                    let next = block[offsetInBlock + 1]
                    try expect(next.hasPrefix("set \(failedCheckVar) to \"") && next != "set \(failedCheckVar) to \"\"", "check `\(line)` must record a failure reason, got: \(next)")
                }
            }
        }
    },

    TestCase(name: "edit_draft_new_window_polls_skip_sheets_and_fail_closed_on_ambiguity") {
        let script = try emitEditDraftScript(send: true)
        let lines = script.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let pollWindowNames = ["viewerID": "eml viewer", "composeID": "compose"]
        for (resultVar, windowName) in pollWindowNames {
            let candidatesVar = "\(resultVar)Candidates"
            let resetIdx = try expectLineIndex(lines, "set \(candidatesVar) to {}")
            let filterIdx = try expectLineIndex(lines, "if candidateName is not \"Save Panel Accessory View\" then set end of \(candidatesVar) to candidateID", after: resetIdx)
            let ambiguousIdx = try expectLineIndex(
                lines,
                "if (count of \(candidatesVar)) > 1 then error \"Mail opened more than one new window while waiting for the \(windowName); refusing to guess which is ours (found \" & (count of \(candidatesVar)) & \")\"",
                after: filterIdx
            )
            let singleIdx = try expectLineIndex(lines, "if (count of \(candidatesVar)) is 1 then", after: ambiguousIdx)
            try expectEqual(lines[singleIdx + 1], "set \(resultVar) to item 1 of \(candidatesVar)")
        }
    },

    // MARK: - Edit-draft --send readiness and bounded retry
    //
    // Live, a Send clicked right after Send Again on a message with an
    // attachment was ignored (or the item was missing) while Mail loaded the
    // attachment into the compose.

    TestCase(name: "edit_draft_send_waits_for_send_menu_item_before_each_click") {
        let lines = trimmedLines(try emitEditDraftScript(send: true))
        let retryStart = try expectLineIndex(lines, sendRetryHeader)
        let readyInit = try expectLineIndex(lines, "set sendMenuReady to false", after: retryStart)
        let readyLoop = try expectLineIndex(lines, "repeat until sendMenuReady or (current date) > sdeadline", after: readyInit)
        let readyRead = try expectLineIndex(
            lines,
            "tell application \"System Events\" to tell process \"Mail\" to set sendMenuReady to (enabled of menu item \"Send\" of menu \"Message\" of menu bar 1 is true)",
            after: readyLoop
        )
        try expectEqual(lines[readyRead - 1], "try")
        try expectEqual(lines[readyRead + 1], "end try")
        let readyError = try expectLineIndex(
            lines,
            "if not sendMenuReady then error \"Mail's Message > Send menu item did not become available within 10s; the compose was not sent\"",
            after: readyRead
        )
        let composeRaise = try expectLineIndex(lines, "tell application \"Mail\" to set index of (first window whose id is composeID) to 1", after: retryStart)
        let sendClick = try expectLineIndex(lines, "click menu item \"Send\" of menu \"Message\" of menu bar 1", after: retryStart)
        try expect(readyError < composeRaise, "the readiness wait must finish before the compose guard starts")
        try expect(composeRaise < sendClick)
        let draftScript = try emitEditDraftScript(send: false)
        try expect(!draftScript.contains("sendMenuReady"), "drafts never wait for Send")
    },

    TestCase(name: "edit_draft_send_retries_click_a_bounded_number_of_times_while_compose_is_open") {
        let rawLines = (try emitEditDraftScript(send: true)).components(separatedBy: "\n")
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }
        let retryStart = try expectLineIndex(rawLines, sendRetryHeader)
        let retryEnd = try expectLineIndex(rawLines, "end repeat", after: retryStart)
        let counterInit = try expectLineIndex(rawLines, "set composeSendClicks to 0")
        try expect(counterInit < retryStart, "the click counter starts at 0 before the retry loop")
        try expectEqual(lines.filter { $0.hasPrefix("set composeSendClicks to") }.count, 2)
        let clickIndexes = (retryStart..<retryEnd).filter { lines[$0] == "click menu item \"Send\" of menu \"Message\" of menu bar 1" }
        try expectEqual(clickIndexes.count, 1)
        // The counter increments right after the guard, which errors unless
        // it clicked, so it counts clicks.
        let guardError = try expectLineIndex(lines, "if not composeIDActed then error \"The compose window did not pass the key-window check within 3s; the Send menu click was not sent. Last failed check: \" & composeIDFailedCheck", after: clickIndexes[0])
        try expectEqual(lines[guardError + 1], "set composeSendClicks to composeSendClicks + 1")
        let goneInit = try expectLineIndex(lines, "set composeIDGone to false", after: guardError)
        try expectEqual(lines[goneInit + 1], "set deadline to (current date) + 3")
        try expect(goneInit < retryEnd, "the per-click gone-poll runs inside the retry loop")
        try expectEqual(rawLines[retryEnd + 1], "if composeIDGone is false then error \"Send did not complete: the compose window is still open after 3 Send menu clicks\"")
    },

    TestCase(name: "edit_draft_send_fails_closed_on_a_sheet_instead_of_clicking_again") {
        let rawLines = (try emitEditDraftScript(send: true)).components(separatedBy: "\n")
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }
        let retryStart = try expectLineIndex(rawLines, sendRetryHeader)
        let retryEnd = try expectLineIndex(rawLines, "end repeat", after: retryStart)
        let counterIncrement = try expectLineIndex(lines, "set composeSendClicks to composeSendClicks + 1", after: retryStart)
        let stillOpen = try expectLineIndex(lines, "if composeIDGone is false then", after: counterIncrement)
        let sheetRead = try expectLineIndex(
            lines,
            "tell application \"System Events\" to tell process \"Mail\" to set composeSheetCount to count of sheets of (value of attribute \"AXMainWindow\")",
            after: stillOpen
        )
        let sheetError = try expectLineIndex(
            lines,
            "if composeSheetCount > 0 then error \"A sheet is open on the compose window after the Send menu click; not clicking Send through it, and the message was not sent\"",
            after: sheetRead
        )
        try expect(sheetError < retryEnd, "the sheet check must run before the next attempt")
        let initIdx = try expectLineIndex(lines, "set composeSheetCount to 0", after: stillOpen)
        try expect(initIdx < sheetRead)
        let frontCheck = try expectLineIndex(lines, "if frontWindowID is composeID then", after: initIdx)
        try expect(frontCheck < sheetRead, "the sheet is read from AXMainWindow only when the compose is Mail's window 1")
    },

    TestCase(name: "ui_action_scan_recognises_every_system_events_action_form") {
        try expect(isUIActionLine("tell process \"Mail\" to keystroke \"d\""))
        try expect(isUIActionLine("    key code 2 using {command down}"))
        try expect(isUIActionLine("perform action \"AXPress\" of button 1"))
        try expect(isUIActionLine("click button \"Send\" of window 1"))
        try expect(!isUIActionLine("if not composeIDActed then error \"not clicking Send; no keystroke\" & composeIDFailedCheck"))
    },
])

private func expectNotNilValue<T>(_ value: T?, _ message: String, file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let value else { throw TestFailure(message: message, file: file, line: line) }
    return value
}

private let frontWindowVars = ["viewerID", "composeID"]

private let sendAgainClick = "click menu item \"Send Again\" of menu \"Message\" of menu bar 1"

private let sendRetryHeader = "repeat while composeIDGone is false and composeSendClicks < 3"

private func trimmedLines(_ script: String) -> [String] {
    script.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
}

private let appleScriptStringLiteral = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
private let uiActionCommand = try! NSRegularExpression(pattern: #"\b(keystroke|key code|perform action|click)\b"#)

/// True when `line`, ignoring the contents of string literals, issues a
/// System Events UI action that lands on whatever window is key.
private func isUIActionLine(_ line: String) -> Bool {
    let fullRange = NSRange(line.startIndex..., in: line)
    let code = appleScriptStringLiteral.stringByReplacingMatches(in: line, range: fullRange, withTemplate: "\"\"")
    return uiActionCommand.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
}

private func emitEditDraftScript(send: Bool) throws -> String {
    var script = ""
    try withTempDir { tmp in
        var opts = Options()
        opts.send = send
        var msg = ParsedMessage()
        msg.subject = "key-window"
        msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
        msg.htmlBody = "<p>rich</p>"
        script = try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: opts, tmp: tmp, runner: Recorder().run)
    }
    return script
}

private func offset(of needle: String, in script: String, file: StaticString = #file, line: UInt = #line) throws -> String.Index {
    guard let range = script.range(of: needle) else {
        throw TestFailure(message: "script does not contain: \(needle)", file: file, line: line)
    }
    return range.lowerBound
}

private func expectLineIndex(_ lines: [String], _ exactLine: String, after start: Int = -1, file: StaticString = #file, line: UInt = #line) throws -> Int {
    guard let found = lines.indices.first(where: { $0 > start && lines[$0] == exactLine }) else {
        throw TestFailure(message: "no line after \(start + 1) equals: \(exactLine)", file: file, line: line)
    }
    return found
}
