import Foundation
import SendmailCore

private let sampleRaw: RawMessage = {
    let bytes = Data("""
    Subject: hi
    From: orig@host
    To: original@to
    Cc: original@cc
    MIME-Version: 1.0
    Content-Type: text/plain; charset=utf-8

    body line one
    body line two
    """.utf8)
    return try! RFC822Parser.parse(bytes)
}()

let emlBuilderTests = TestSuite(name: "EmlBuilder", cases: [
    TestCase(name: "passes_body_bytes_through_verbatim") {
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "a@b")]
        let out = EmlBuilder.buildEml(raw: sampleRaw, finalRecipients: msg, options: Options())
        let s = String(data: out, encoding: .utf8) ?? ""
        try expect(s.contains("body line one\nbody line two"))
    },

    TestCase(name: "long_header_lines_are_folded_within_998_octets") {
        let references = (0..<40).map { "<message-id-\($0).1234567890@mail.example.test>" }
        let source = try RFC822Parser.parse(Data(
            "Subject: hi\nReferences: \(references.joined(separator: "\n "))\nContent-Type: text/plain\n\nbody\n".utf8
        ))
        var msg = ParsedMessage()
        msg.to = (0..<40).map { ParsedAddress(displayName: "Recipient \($0)", address: "recipient-\($0)@example.test") }
        let out = EmlBuilder.buildEml(raw: source, finalRecipients: msg, options: Options())
        let headerSection = String(decoding: out, as: UTF8.self).components(separatedBy: "\r\n\r\n")[0]
        for line in headerSection.components(separatedBy: "\r\n") {
            try expect(line.utf8.count <= 998, "line of \(line.utf8.count) octets: \(line.prefix(40))...")
        }
        let reparsed = try RFC822Parser.parse(out)
        try expectEqual(reparsed.value(for: "References"), references.joined(separator: " "))
        let reparsedTo = AddressParser.parse(reparsed.value(for: "To") ?? "")
        try expectEqual(reparsedTo.map(\.address), msg.to.map(\.address))
        try expectEqual(reparsedTo.map(\.displayName), msg.to.map(\.displayName))
    },

    TestCase(name: "replaces_to_with_finalized_recipients") {
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "new@to")]
        let out = EmlBuilder.buildEml(raw: sampleRaw, finalRecipients: msg, options: Options())
        let s = String(data: out, encoding: .utf8) ?? ""
        try expect(s.contains("To: new@to"))
        try expect(!s.contains("To: original@to"), "old To should be stripped")
    },

    TestCase(name: "strips_cc_when_finalized_cc_is_empty") {
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "a@b")]
        let out = EmlBuilder.buildEml(raw: sampleRaw, finalRecipients: msg, options: Options())
        let s = String(data: out, encoding: .utf8) ?? ""
        try expect(!s.contains("Cc:"), "Cc must be stripped when finalRecipients.cc is empty")
    },

    TestCase(name: "from_override_replaces_existing_From") {
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "a@b")]
        var opts = Options()
        opts.fromAddress = "new@from"
        let out = EmlBuilder.buildEml(raw: sampleRaw, finalRecipients: msg, options: opts)
        let s = String(data: out, encoding: .utf8) ?? ""
        try expect(s.contains("From: new@from"))
        try expect(!s.contains("From: orig@host"))
    },

    TestCase(name: "from_with_name_uses_name_address_format") {
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "a@b")]
        var opts = Options()
        opts.fromAddress = "bot@x.com"
        opts.fromName = "Build Bot"
        let out = EmlBuilder.buildEml(raw: sampleRaw, finalRecipients: msg, options: opts)
        let s = String(data: out, encoding: .utf8) ?? ""
        try expect(s.contains("From: Build Bot <bot@x.com>"))
    },

    TestCase(name: "no_from_override_preserves_original") {
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "a@b")]
        let out = EmlBuilder.buildEml(raw: sampleRaw, finalRecipients: msg, options: Options())
        let s = String(data: out, encoding: .utf8) ?? ""
        try expect(s.contains("From: orig@host"))
    },

    TestCase(name: "F_without_f_leaves_header_From_unchanged") {
        let raw = try RFC822Parser.parse(Data("""
        From: "Work Bot" <work@example.test>
        To: u@example.test
        Content-Type: text/plain

        body
        """.utf8))
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "u@example.test")]
        var opts = Options()
        opts.fromName = "Ignored Name"
        let out = EmlBuilder.buildEml(raw: raw, finalRecipients: msg, options: opts)
        let s = String(data: out, encoding: .utf8) ?? ""
        try expect(s.contains("From: \"Work Bot\" <work@example.test>\r\n"))
        try expect(!s.contains("Ignored Name"))
    },

    TestCase(name: "headers_use_crlf_line_endings") {
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "a@b")]
        let out = EmlBuilder.buildEml(raw: sampleRaw, finalRecipients: msg, options: Options())
        let s = String(data: out, encoding: .utf8) ?? ""
        try expect(s.contains("To: a@b\r\n"))
        try expect(s.contains("\r\n\r\nbody line one"), "header/body separator must be a blank CRLF line")
    },

    TestCase(name: "shared_mailbox_formatting_matches_plain_sender") {
        var opts = Options()
        opts.fromName = "Build Bot"
        opts.fromAddress = "bot@x.com"
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "a@b")]
        let out = EmlBuilder.buildEml(raw: sampleRaw, finalRecipients: msg, options: opts)
        let eml = String(data: out, encoding: .utf8) ?? ""
        try expect(eml.contains("From: Build Bot <bot@x.com>"))
        var plain = ParsedMessage()
        plain.to = [ParsedAddress(displayName: nil, address: "a@b")]
        plain.body = "hi"
        try expectEqual(try plainSender(plain, options: opts), "Build Bot <bot@x.com>")
        var withCc = ParsedMessage()
        withCc.to = [ParsedAddress(displayName: "Alice A", address: "alice@x")]
        let out2 = EmlBuilder.buildEml(raw: sampleRaw, finalRecipients: withCc, options: Options())
        let eml2 = String(data: out2, encoding: .utf8) ?? ""
        try expect(eml2.contains("To: Alice A <alice@x>"))
    },

    TestCase(name: "crlf_in_display_name_does_not_inject_header") {
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: "Alice\r\nBcc: evil@x", address: "a@b")]
        let out = EmlBuilder.buildEml(raw: sampleRaw, finalRecipients: msg, options: Options())
        let s = String(data: out, encoding: .utf8) ?? ""
        let headerBlock = s.components(separatedBy: "\r\n\r\n").first ?? s
        let headerLines = headerBlock.components(separatedBy: "\r\n")
        try expect(!headerLines.contains { $0.hasPrefix("Bcc:") }, "no injected Bcc: header line")
        try expect(!s.contains("\r\nBcc: evil@x"), "the CRLF must be neutralized, not preserved")
        try expect(s.contains("a@b"))
    },

    TestCase(name: "crlf_in_from_override_does_not_inject_header") {
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "a@b")]
        var opts = Options()
        opts.fromAddress = "x@y\r\nX-Evil: 1"
        let out = EmlBuilder.buildEml(raw: sampleRaw, finalRecipients: msg, options: opts)
        let s = String(data: out, encoding: .utf8) ?? ""
        let headerBlock = s.components(separatedBy: "\r\n\r\n").first ?? s
        let headerLines = headerBlock.components(separatedBy: "\r\n")
        try expect(!headerLines.contains { $0.hasPrefix("X-Evil:") }, "no injected X-Evil: header line")
    },

    TestCase(name: "round_trip_through_parser_preserves_html_body") {
        let html = "<html><body><table><tr><td>X</td></tr></table></body></html>"
        let bytes = Data("""
        Subject: round-trip
        From: me@host
        MIME-Version: 1.0
        Content-Type: text/html; charset=utf-8

        \(html)
        """.utf8)
        let r = try RFC822Parser.parse(bytes)
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "you@host")]
        let out = EmlBuilder.buildEml(raw: r, finalRecipients: msg, options: Options())
        let s = String(data: out, encoding: .utf8) ?? ""
        try expect(s.contains("<table>"))
        try expect(s.contains("<td>X</td>"))
        try expect(s.contains("To: you@host"))
    },

    TestCase(name: "bcc_only_message_gets_no_to_header") {
        let bytes = Data("""
        Subject: bcc only
        From: me@host.test
        To: undisclosed-recipients:;
        Bcc: hidden@x.test
        Content-Type: text/plain; charset=utf-8

        body
        """.utf8)
        let raw = try RFC822Parser.parse(bytes)
        let msg = MIMEParser.parse(raw)
        try expect(msg.to.isEmpty, "empty group must not become a To recipient")
        try expectEqual(msg.bcc.map(\.address), ["hidden@x.test"])
        let out = EmlBuilder.buildEml(raw: raw, finalRecipients: msg, options: Options())
        let s = String(data: out, encoding: .utf8) ?? ""
        let headerLines = s.components(separatedBy: "\r\n\r\n")[0].components(separatedBy: "\r\n")
        let toLines = headerLines.filter { $0.lowercased().hasPrefix("to:") }
        try expectEqual(toLines, [])
        try expect(headerLines.contains("Bcc: hidden@x.test"))

        let reparsedRaw = try RFC822Parser.parse(out)
        let reparsed = MIMEParser.parse(reparsedRaw)
        try expect(reparsed.to.isEmpty, "re-parse must give zero To recipients")
        try expectEqual(reparsed.bcc.map(\.address), ["hidden@x.test"])
    },

    TestCase(name: "to_header_omitted_when_there_are_no_recipients") {
        let out = EmlBuilder.buildEml(raw: sampleRaw, finalRecipients: ParsedMessage(), options: Options())
        let s = String(data: out, encoding: .utf8) ?? ""
        try expect(!s.contains("To:"), "no To header without any recipient")
    },

    TestCase(name: "cc_only_message_gets_no_to_header") {
        var msg = ParsedMessage()
        msg.cc = [ParsedAddress(displayName: nil, address: "copied@x.test")]
        let out = EmlBuilder.buildEml(raw: sampleRaw, finalRecipients: msg, options: Options())
        let s = String(data: out, encoding: .utf8) ?? ""
        let headerLines = s.components(separatedBy: "\r\n\r\n")[0].components(separatedBy: "\r\n")
        try expect(!headerLines.contains { $0.lowercased().hasPrefix("to:") }, "empty To must be omitted even with Cc present")
        try expect(headerLines.contains("Cc: copied@x.test"))
    },
])
