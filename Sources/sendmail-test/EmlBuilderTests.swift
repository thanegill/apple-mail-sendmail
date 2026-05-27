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
        // msg.cc is empty
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

    TestCase(name: "headers_use_crlf_line_endings") {
        var msg = ParsedMessage()
        msg.to = [ParsedAddress(displayName: nil, address: "a@b")]
        let out = EmlBuilder.buildEml(raw: sampleRaw, finalRecipients: msg, options: Options())
        let s = String(data: out, encoding: .utf8) ?? ""
        try expect(s.contains("To: a@b\r\n"))
        try expect(s.contains("\r\n\r\nbody line one"), "header/body separator must be a blank CRLF line")
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
])
