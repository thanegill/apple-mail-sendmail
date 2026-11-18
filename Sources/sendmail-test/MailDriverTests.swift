import Foundation
import SendmailCore

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

/// Run `msg` through the plain path and return the recorded Apple Events.
private func plainEvents(_ msg: ParsedMessage, options: Options = Options(), emlBytes: Data? = nil) throws -> AppleEventRecorder {
    let recorder = AppleEventRecorder()
    try withTempDir { tmp in
        try MailDriver.deliver(msg, emlBytes: emlBytes ?? syntheticEml(for: msg), options: options, tmp: tmp, recorder: recorder)
    }
    return recorder
}

/// Run a plain-text message with the given raw `From:` value through the
/// real parsers and the plain path.
private func plainEvents(fromHeader: String) throws -> AppleEventRecorder {
    let input = "From: \(fromHeader)\nTo: u@example.test\nSubject: s\nContent-Type: text/plain\n\nbody\n"
    let msg = MIMEParser.parse(try RFC822Parser.parse(Data(input.utf8)))
    return try plainEvents(msg, emlBytes: Data(input.utf8))
}

private func message(to address: String = "u@h", subject: String = "s", body: String = "b") -> ParsedMessage {
    var msg = ParsedMessage()
    msg.subject = subject
    msg.to = [ParsedAddress(displayName: nil, address: address)]
    msg.body = body
    return msg
}

/// Deliver a plain message with `--send`, its events going to `recorder`.
private func sendThroughPlainPath(_ recorder: AppleEventRecorder) throws {
    var opts = Options()
    opts.send = true
    try withTempDir { tmp in
        let msg = message()
        try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: opts, tmp: tmp, recorder: recorder)
    }
}

private let messageContent = AEValue.specifier(want: "prop", from: recordedMessageSpecifier, form: "prop", seld: .type("ctnt"))

let mailDriverTests = TestSuite(name: "MailDriver", cases: [
    // MARK: - Plain path events

    TestCase(name: "draft_mode_makes_a_visible_message_and_never_sends") {
        var msg = message(subject: "Hello", body: "Body.")
        msg.to = [ParsedAddress(displayName: "Alice", address: "alice@example.com")]
        let recorder = try plainEvents(msg)
        try expectEqual(recorder.names, ["core/crel", "core/setd", "core/crel"])
        try expectEqual(recorder.messageProperties["pvis"], .bool(true))
        try expectEqual(recorder.messageProperties["subj"], .text("Hello"))
        try expect(!recorder.names.contains("emsg/send"), "a draft must not be sent")
        let recipient = recorder.creations(of: "trcp")
        try expectEqual(recipient.count, 1)
        try expectEqual(recipient[0].params["prdt"], .record(["radd": .text("alice@example.com"), "pnam": .text("Alice")]))
    },

    TestCase(name: "send_mode_makes_an_invisible_message_and_sends_it_last") {
        var opts = Options()
        opts.send = true
        let recorder = try plainEvents(message(to: "x@y", subject: "S"), options: opts)
        try expectEqual(recorder.messageProperties["pvis"], .bool(false))
        try expectEqual(recorder.names.last, "emsg/send")
        try expectEqual(recorder.names.filter { $0 == "emsg/send" }.count, 1)
        try expectEqual(recorder.events.last?.params["----"], recordedMessageSpecifier)
    },

    TestCase(name: "every_event_targets_mail_by_bundle_id") {
        var opts = Options()
        opts.send = true
        let recorder = try plainEvents(message(), options: opts)
        for event in recorder.events {
            try expectEqual(event.target, "com.apple.mail")
        }
    },

    TestCase(name: "make_message_names_the_outgoing_message_class_and_nothing_else") {
        let recorder = try plainEvents(message())
        let make = recorder.events[0]
        try expectEqual(make.name, "core/crel")
        try expectEqual(Set(make.params.keys), ["kocl", "prdt"])
        try expectEqual(make.params["kocl"], .type("bcke"))
    },

    TestCase(name: "sender_combined_from_F_and_f") {
        var opts = Options()
        opts.fromName = "Bot"
        opts.fromAddress = "bot@x.com"
        let recorder = try plainEvents(message(to: "u@h"), options: opts)
        try expectEqual(recorder.messageProperties["sndr"], .text("Bot <bot@x.com>"))
    },

    TestCase(name: "sender_address_only") {
        var opts = Options()
        opts.fromAddress = "bare@x.com"
        let recorder = try plainEvents(message(to: "u@h"), options: opts)
        try expectEqual(recorder.messageProperties["sndr"], .text("bare@x.com"))
    },

    TestCase(name: "sender_f_without_domain_passed_through") {
        var opts = Options()
        opts.fromAddress = "root"
        let recorder = try plainEvents(message(to: "u@example.test"), options: opts)
        // The header-From domain check must not filter an explicit -f.
        try expectEqual(recorder.messageProperties["sndr"], .text("root"))
    },

    TestCase(name: "sender_from_header_when_no_f") {
        var msg = message(to: "u@example.test")
        msg.from = ParsedAddress(displayName: nil, address: "work@example.test")
        let recorder = try plainEvents(msg)
        try expectEqual(recorder.messageProperties["sndr"], .text("work@example.test"))
    },

    TestCase(name: "sender_f_overrides_header_from") {
        var opts = Options()
        opts.fromAddress = "cli@example.test"
        var msg = message(to: "u@example.test")
        msg.from = ParsedAddress(displayName: "Work Bot", address: "work@example.test")
        let recorder = try plainEvents(msg, options: opts)
        try expectEqual(recorder.messageProperties["sndr"], .text("cli@example.test"))
        try expect(!recorder.allTexts.contains { $0.contains("work@example.test") }, "-f must fully replace the header From, display name included")
    },

    TestCase(name: "sender_F_without_f_keeps_header_from") {
        var opts = Options()
        opts.fromName = "Ignored Name"
        var msg = message(to: "u@example.test")
        msg.from = ParsedAddress(displayName: "Work Bot", address: "work@example.test")
        let recorder = try plainEvents(msg, options: opts)
        try expectEqual(recorder.messageProperties["sndr"], .text("Work Bot <work@example.test>"))
        try expect(!recorder.allTexts.contains { $0.contains("Ignored Name") })
    },

    TestCase(name: "sender_omitted_without_f_or_header_from") {
        var opts = Options()
        opts.fromName = "Ignored Name"
        let recorder = try plainEvents(message(to: "u@example.test"), options: opts)
        try expectNil(recorder.messageProperties["sndr"])
        try expectEqual(Set(recorder.messageProperties.keys), ["subj", "pvis"])
    },

    TestCase(name: "sender_omitted_for_cron_daemon_header_from") {
        try expectNil(try plainEvents(fromHeader: "root (Cron Daemon)").messageProperties["sndr"])
    },

    TestCase(name: "sender_omitted_for_bare_local_header_from") {
        try expectNil(try plainEvents(fromHeader: "root").messageProperties["sndr"])
    },

    TestCase(name: "sender_omitted_for_empty_group_header_from") {
        try expectNil(try plainEvents(fromHeader: "undisclosed-recipients:;").messageProperties["sndr"])
    },

    TestCase(name: "sender_from_parsed_header_with_encoded_display_name") {
        let input = """
        From: =?UTF-8?B?QsO8cm8gQm90?= <work@example.test>
        To: u@example.test
        Subject: cron
        Content-Type: text/plain; charset=utf-8

        plain body
        """
        let msg = MIMEParser.parse(try RFC822Parser.parse(Data(input.utf8)))
        let recorder = try plainEvents(msg, emlBytes: Data(input.utf8))
        try expectEqual(recorder.messageProperties["sndr"], .text("Büro Bot <work@example.test>"))
    },

    TestCase(name: "to_cc_and_bcc_recipients_are_made_at_the_end_of_their_own_list") {
        var msg = message(to: "a@x")
        msg.cc = [ParsedAddress(displayName: nil, address: "b@y")]
        msg.bcc = [ParsedAddress(displayName: nil, address: "c@z")]
        let recorder = try plainEvents(msg)
        for (classCode, address) in [("trcp", "a@x"), ("crcp", "b@y"), ("brcp", "c@z")] {
            let made = recorder.creations(of: classCode)
            try expectEqual(made.count, 1)
            try expectEqual(made[0].params["prdt"], .record(["radd": .text(address)]))
            try expectEqual(
                made[0].params["insh"],
                .insertion(position: "end ", object: .specifier(want: classCode, from: recordedMessageSpecifier, form: "indx", seld: .ordinal("all ")))
            )
        }
        try expectEqual(recorder.names, ["core/crel", "core/setd", "core/crel", "core/crel", "core/crel"])
    },

    TestCase(name: "recipient_without_a_display_name_sets_no_name") {
        var msg = message(to: "a@x")
        msg.to.append(ParsedAddress(displayName: "", address: "b@x"))
        let recorder = try plainEvents(msg)
        try expectEqual(recorder.creations(of: "trcp").map { $0.params["prdt"] }, [
            .record(["radd": .text("a@x")]),
            .record(["radd": .text("b@x")]),
        ])
    },

    TestCase(name: "attachment_makes_temp_file_and_attaches_it_after_the_last_paragraph") {
        try withTempDir { tmp in
            let recorder = AppleEventRecorder()
            var msg = message()
            msg.attachments = [
                Attachment(filename: "note.txt", contentType: "text/plain", data: Data("hello\n".utf8))
            ]
            var attachedData: Data?
            recorder.onSend = { event in
                if event.params["kocl"] == .type("atts"), case let .record(fields)? = event.params["prdt"], case let .fileURL(path)? = fields["atfn"] {
                    attachedData = try Data(contentsOf: URL(fileURLWithPath: path))
                    try expect(URL(fileURLWithPath: path).lastPathComponent == "att-01-note.txt", "unexpected staged name \(path)")
                    try expectEqual(URL(fileURLWithPath: path).deletingLastPathComponent().path, tmp.url.path)
                }
            }
            try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, recorder: recorder)
            try expectEqual(attachedData, Data("hello\n".utf8))
            let attach = recorder.creations(of: "atts")
            try expectEqual(attach.count, 1)
            try expectEqual(
                attach[0].params["insh"],
                .insertion(position: "afte", object: .specifier(want: "cpar", from: messageContent, form: "indx", seld: .ordinal("last")))
            )
        }
    },

    TestCase(name: "attachments_come_after_recipients_and_before_send") {
        var opts = Options()
        opts.send = true
        var msg = message()
        msg.attachments = [
            Attachment(filename: "a.txt", contentType: "text/plain", data: Data("a".utf8)),
            Attachment(filename: "b.txt", contentType: "text/plain", data: Data("b".utf8)),
        ]
        let recorder = try plainEvents(msg, options: opts)
        let kinds = recorder.events.map { $0.params["kocl"].map(\.description) ?? $0.name }
        try expectEqual(kinds, ["type(bcke)", "core/setd", "type(trcp)", "type(atts)", "type(atts)", "emsg/send"])
    },

    TestCase(name: "body_is_set_as_text_verbatim_without_a_temp_file") {
        try withTempDir { tmp in
            let recorder = AppleEventRecorder()
            let msg = message(body: "Body with \"quotes\" and \\backslashes.\nline two")
            try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, recorder: recorder)
            let setContent = recorder.events.filter { $0.name == "core/setd" }
            try expectEqual(setContent.count, 1)
            try expectEqual(setContent[0].params["----"], messageContent)
            try expectEqual(setContent[0].params["data"], .text("Body with \"quotes\" and \\backslashes.\nline two"))
            try expect(!FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("body.txt").path), "the body needs no file any more")
        }
    },

    TestCase(name: "subject_is_passed_verbatim") {
        for subject in ["He said \"hi\" \\", "before\u{2028}after\u{2029}end", "a\r\nb", "caf\u{E9} \u{1F600}"] {
            let recorder = try plainEvents(message(subject: subject))
            try expectEqual(recorder.messageProperties["subj"], .text(subject))
        }
    },

    TestCase(name: "encoded_subject_stays_one_text_parameter") {
        // What once had to be escaped into an AppleScript literal is now one
        // text parameter, whatever it contains.
        let payload = "X\u{0600}\" & (count {1, 2, 3}) & (character id {80, 87, 78}) & \"\u{0301}"
        let encoded = "=?UTF-8?B?" + Data(payload.utf8).base64EncodedString() + "?="
        let eml = Data("To: u@h\r\nSubject: \(encoded)\r\n\r\nbody\r\n".utf8)
        let msg = MIMEParser.parse(try RFC822Parser.parse(eml))
        try expectEqual(msg.subject, payload)
        let recorder = try plainEvents(msg, emlBytes: eml)
        try expectEqual(recorder.messageProperties["subj"], .text(payload))
        try expectEqual(recorder.names, ["core/crel", "core/setd", "core/crel"])
    },

    TestCase(name: "no_attachments_means_no_attachment_event") {
        let recorder = try plainEvents(message())
        try expect(recorder.creations(of: "atts").isEmpty)
    },

    TestCase(name: "plain_path_launches_mail_without_activating_it_when_not_running") {
        try withTempDir { tmp in
            let recorder = AppleEventRecorder()
            let mail = FakeMail()
            mail.mailRunning = false
            let automation = MailAutomation(plain: AppleEventPlainDelivery(events: recorder, workspace: mail, clock: mail), html: RecordingHTMLDelivery())
            let msg = message()
            try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, automation: automation)
            try expectEqual(mail.launches, 1)
            try expect(mail.openedURLs.isEmpty)
            try expectEqual(recorder.names.first, "core/crel")
        }
    },

    TestCase(name: "plain_path_stops_at_the_first_failed_event") {
        let recorder = AppleEventRecorder()
        recorder.failure = (index: 0, error: AppleEventError(code: -1743, message: "Not authorized to send Apple events to Mail."))
        var opts = Options()
        opts.send = true
        var thrown: Error?
        do {
            try withTempDir { tmp in
                let msg = message()
                try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: opts, tmp: tmp, recorder: recorder)
            }
        } catch {
            thrown = error
        }
        try expectEqual((thrown as? AppleEventError)?.code, -1743)
        try expectEqual(recorder.events.count, 1)
    },

    TestCase(name: "a_failed_recipient_never_reaches_send") {
        let recorder = AppleEventRecorder()
        recorder.failure = (index: 2, error: AppleEventError(code: -10000, message: "Apple event handler failed."))
        var opts = Options()
        opts.send = true
        var thrown: Error?
        do {
            try withTempDir { tmp in
                let msg = message()
                try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: opts, tmp: tmp, recorder: recorder)
            }
        } catch {
            thrown = error
        }
        try expectEqual((thrown as? AppleEventError)?.code, -10000)
        try expect(!recorder.names.contains("emsg/send"))
    },

    TestCase(name: "send_answered_false_fails_with_exit_oserr") {
        let recorder = AppleEventRecorder()
        recorder.sendResult = NSAppleEventDescriptor(boolean: false)
        var thrown: Error?
        do {
            try sendThroughPlainPath(recorder)
        } catch {
            thrown = error
        }
        try expectEqual(recorder.names.last, "emsg/send")
        guard let thrown else { throw TestFailure(message: "a false send reply must fail", file: #file, line: #line) }
        let report = FailureReport(thrown)
        try expectEqual(report.exitCode, .osErr)
        try expect(report.message.contains("did not send the message"), report.message)
        try expect(report.message.contains("returned false"), report.message)
    },

    TestCase(name: "send_answered_true_succeeds") {
        let recorder = AppleEventRecorder()
        recorder.sendResult = NSAppleEventDescriptor(boolean: true)
        try sendThroughPlainPath(recorder)
        try expectEqual(recorder.names.last, "emsg/send")
    },

    TestCase(name: "send_reply_without_a_boolean_result_keeps_succeeding") {
        let results: [NSAppleEventDescriptor?] = [
            nil,
            NSAppleEventDescriptor(int32: 0),
            NSAppleEventDescriptor(string: "false"),
            NSAppleEventDescriptor.null(),
        ]
        for result in results {
            let recorder = AppleEventRecorder()
            recorder.sendResult = result
            try sendThroughPlainPath(recorder)
            try expectEqual(recorder.names.last, "emsg/send")
        }
    },

    TestCase(name: "make_message_reply_without_a_message_is_an_error_before_anything_else") {
        let recorder = AppleEventRecorder()
        recorder.replyWithoutMessage = true
        var thrown: Error?
        do {
            try withTempDir { tmp in
                let msg = message()
                try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, recorder: recorder)
            }
        } catch {
            thrown = error
        }
        try expectEqual(thrown as? DeliveryError, DeliveryError("Mail did not return the new outgoing message"))
        try expectEqual(recorder.events.count, 1)
    },

    // MARK: - Plain plan and dry run

    TestCase(name: "plain_plan_prints_one_json_object_per_step") {
        let compose = PlainCompose(
            subject: "Hi \"there\"", sender: "Ops <ops@example.test>", body: "line\nnext",
            to: [ParsedAddress(displayName: "A", address: "a@example.test")],
            cc: [ParsedAddress(displayName: nil, address: "c@example.test")],
            bcc: [],
            attachmentURLs: [URL(fileURLWithPath: "/tmp/x/att-01-a.txt")],
            send: true
        )
        try expectEqual(PlainPlan.jsonLines(PlainPlan.steps(compose)), [
            #"{"activates":false,"step":"launch_mail","timeout_ms":10000}"#,
            #"{"sender":"Ops <ops@example.test>","step":"make_message","subject":"Hi \"there\"","visible":false}"#,
            #"{"step":"set_content","text":"line\nnext"}"#,
            #"{"address":"a@example.test","kind":"to","name":"A","step":"add_recipient"}"#,
            #"{"address":"c@example.test","kind":"cc","name":null,"step":"add_recipient"}"#,
            #"{"path":"/tmp/x/att-01-a.txt","step":"add_attachment"}"#,
            #"{"step":"send"}"#,
        ])
    },

    TestCase(name: "plain_draft_plan_has_no_send_and_a_null_sender_when_none_is_set") {
        let compose = PlainCompose(subject: "s", sender: nil, body: "b", to: [ParsedAddress(displayName: nil, address: "a@x")], cc: [], bcc: [], attachmentURLs: [], send: false)
        let lines = PlainPlan.jsonLines(PlainPlan.steps(compose))
        try expectEqual(lines[1], #"{"sender":null,"step":"make_message","subject":"s","visible":true}"#)
        try expect(!lines.contains(#"{"step":"send"}"#))
    },

    TestCase(name: "each_plan_step_after_launch_sends_exactly_one_event") {
        var opts = Options()
        opts.send = true
        var msg = message()
        msg.cc = [ParsedAddress(displayName: nil, address: "c@x")]
        msg.attachments = [Attachment(filename: "a.txt", contentType: "text/plain", data: Data("a".utf8))]
        try withTempDir { tmp in
            var printed: [String] = []
            let printer = MailAutomation(plain: PlainPlanPrinter { printed.append($0) }, html: RecordingHTMLDelivery())
            try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: opts, tmp: tmp, automation: printer)
            let recorder = AppleEventRecorder()
            try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: opts, tmp: tmp, recorder: recorder)
            try expectEqual(recorder.events.count, printed.count - 1)
        }
    },

    TestCase(name: "plain_plan_printer_sends_no_events_and_launches_nothing") {
        // The printer has no Apple Event or Launch Services dependency at all;
        // this checks it still stages the attachment it names.
        try withTempDir { tmp in
            var printed: [String] = []
            var msg = message()
            msg.attachments = [Attachment(filename: "a.txt", contentType: "text/plain", data: Data("a".utf8))]
            let printer = MailAutomation(plain: PlainPlanPrinter { printed.append($0) }, html: RecordingHTMLDelivery())
            try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, automation: printer)
            let attachLine = printed.first { $0.contains(#""step":"add_attachment""#) } ?? ""
            let path = tmp.url.appendingPathComponent("att-01-a.txt").path
            try expect(attachLine.contains(path), "attachment step must name the staged file: \(attachLine)")
            try expect(FileManager.default.fileExists(atPath: path))
        }
    },

    // MARK: - HTML path routing
    //
    // The HTML path's own steps are covered by the AXHTMLDelivery suite;
    // these check what MailDriver hands it.

    TestCase(name: "html_message_hands_its_eml_to_the_html_path_and_sends_no_apple_event") {
        try withTempDir { tmp in
            let recorder = AppleEventRecorder()
            let html = RecordingHTMLDelivery()
            var msg = ParsedMessage()
            msg.subject = "rich-html-subj"
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.htmlBody = "<p>rich</p>"
            try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, recorder: recorder, html: html)
            try expect(recorder.events.isEmpty, "an HTML message must not send Apple Events")
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
                try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: opts, tmp: tmp, recorder: AppleEventRecorder(), html: html)
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
            try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, recorder: AppleEventRecorder())
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
        // path, which bypasses the plain path's attachment events -- the
        // attachment rides inside the raw .eml instead. Verified live
        // (2026-07-09): note7.txt arrived attached. This guards that the .eml
        // handed to Mail still carries the attachment part and that the plain
        // attach step does not run for HTML messages.
        try withTempDir { tmp in
            let recorder = AppleEventRecorder()
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
            try MailDriver.deliver(msg, emlBytes: Data(emlText.utf8), options: Options(), tmp: tmp, recorder: recorder, html: html)
            try expectEqual(html.calls.count, 1)
            try expect(recorder.events.isEmpty, "the plain attachment events are bypassed for HTML messages")
            let files = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
            try expect(!files.contains { $0.hasPrefix("att-") }, "HTML messages stage no attachment files")
            let written = String(data: try Data(contentsOf: html.calls[0].url), encoding: .utf8) ?? ""
            try expect(written.contains("Content-Disposition: attachment"), "attachment disposition must survive into the .eml")
            try expect(written.contains("filename=\"note7.txt\""), "the .eml handed to Mail must still carry the attachment part")
        }
    },

    TestCase(name: "html_path_skipped_when_html_body_is_whitespace_only") {
        try withTempDir { tmp in
            let recorder = AppleEventRecorder()
            let html = RecordingHTMLDelivery()
            var msg = ParsedMessage()
            msg.to = [ParsedAddress(displayName: nil, address: "u@h")]
            msg.body = "plain"
            msg.htmlBody = "   \n\t  \n"
            try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, recorder: recorder, html: html)
            try expect(html.calls.isEmpty)
            try expect(recorder.names.contains("core/setd"))
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
            try MailDriver.deliver(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, recorder: AppleEventRecorder(), html: html)
            try expect(html.calls.count == 1, "wrapper-with-html must take the HTML path")
        }
    },

    // MARK: - Temp-dir cleanup

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
        try MailDriver.deliverThenCleanUp(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, automation: recordingAutomation(AppleEventRecorder(), html: html))
        try expect(filesSeenByDelivery.contains { $0.hasSuffix(".eml") }, "eml must exist while the HTML path runs")
        try expect(!FileManager.default.fileExists(atPath: tmp.url.path), "temp dir left behind after success")
    },

    TestCase(name: "deliver_then_clean_up_removes_tmp_after_plain_success") {
        let tmp = try TempDir()
        defer { tmp.cleanup() }
        var filesSeenWhileSending: [String] = []
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "rcpt@example.test")]
        msg.body = "plain"
        msg.attachments = [
            Attachment(filename: "note.txt", contentType: "text/plain", data: Data("hello\n".utf8))
        ]
        let recorder = AppleEventRecorder()
        recorder.onSend = { _ in
            filesSeenWhileSending = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
        }
        try MailDriver.deliverThenCleanUp(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, automation: recordingAutomation(recorder))
        try expect(filesSeenWhileSending.contains { $0.hasPrefix("att-") }, "attachment must exist while the events are sent")
        try expect(!FileManager.default.fileExists(atPath: tmp.url.path), "temp dir left behind after success")
    },

    TestCase(name: "deliver_then_clean_up_removes_tmp_when_delivery_throws") {
        let tmp = try TempDir()
        defer { tmp.cleanup() }
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "rcpt@example.test")]
        msg.body = "plain"
        let recorder = AppleEventRecorder()
        recorder.failure = (index: 0, error: AppleEventError(code: -1743, message: "denied"))
        var thrown: Error?
        do {
            try MailDriver.deliverThenCleanUp(msg, emlBytes: syntheticEml(for: msg), options: Options(), tmp: tmp, automation: recordingAutomation(recorder))
        } catch {
            thrown = error
        }
        try expectEqual((thrown as? AppleEventError)?.code, -1743)
        try expect(!FileManager.default.fileExists(atPath: tmp.url.path), "temp dir left behind after a delivery failure")
    },
])
