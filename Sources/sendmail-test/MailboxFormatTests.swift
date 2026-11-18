import Foundation
import SendmailCore

private let plainRaw: RawMessage = {
    let bytes = Data("""
    Subject: hi
    From: orig@origin.example.test
    MIME-Version: 1.0
    Content-Type: text/plain; charset=utf-8

    body
    """.utf8)
    return try! RFC822Parser.parse(bytes)
}()

private func headerValue(_ name: String, inEml eml: Data) throws -> String {
    let reparsed = try RFC822Parser.parse(eml)
    guard let value = reparsed.headers.first(where: { $0.0.lowercased() == name.lowercased() })?.1 else {
        throw TestFailure(message: "no \(name) header in .eml", file: #file, line: #line)
    }
    return value
}

private func emlWithTo(_ recipients: [ParsedAddress], options: Options = Options()) -> Data {
    var msg = ParsedMessage()
    msg.to = recipients
    return EmlBuilder.buildEml(raw: plainRaw, finalRecipients: msg, options: options)
}

private func plainSender(fromName: String, fromAddress: String) throws -> String? {
    var opts = Options()
    opts.fromName = fromName
    opts.fromAddress = fromAddress
    var msg = ParsedMessage()
    msg.to = [ParsedAddress(displayName: nil, address: "u@example.test")]
    msg.body = "hi"
    return try plainSender(msg, options: opts)
}

private func roundTripToHeader(_ rawToValue: String) throws -> (parsed: ParsedAddress, emlTo: String, reparsed: [ParsedAddress]) {
    let source = try RFC822Parser.parse(Data("Subject: hi\nTo: \(rawToValue)\nContent-Type: text/plain\n\nbody\n".utf8))
    let parsed = MIMEParser.parse(source)
    try expectEqual(parsed.to.count, 1)
    let eml = EmlBuilder.buildEml(raw: source, finalRecipients: parsed, options: Options())
    let emlTo = try headerValue("To", inEml: eml)
    return (parsed.to[0], emlTo, AddressParser.parse(emlTo))
}

private func expectEncodedWordsSplitBetweenScalars(_ input: String) throws {
    let encoded = EncodedWord.encode(input)
    let encodedWords = encoded.split(separator: " ")
    try expect(encodedWords.count > 1, "expected several encoded-words, got \(encoded)")
    for word in encodedWords {
        try expect(word.count <= 75, "encoded-word over 75 chars: \(word)")
        let payload = word.dropFirst("=?UTF-8?B?".count).dropLast("?=".count)
        let bytes = Data(base64Encoded: String(payload)) ?? Data()
        try expect(String(data: bytes, encoding: .utf8) != nil, "encoded-word \(word) splits a character")
    }
    let decoded = EncodedWord.decode(encoded)
    try expect(Array(decoded.unicodeScalars) == Array(input.unicodeScalars), "round trip changed \(input) into \(decoded)")
}

let mailboxFormatTests = TestSuite(name: "MailboxFormat", cases: [
    TestCase(name: "quoted_pair_display_name_round_trips_without_double_escaping") {
        let bob = try roundTripToHeader(#""Smith \"Bob\"" <a@x.test>"#)
        try expectEqual(bob.parsed.displayName, #"Smith "Bob""#)
        try expectEqual(bob.emlTo, #""Smith \"Bob\"" <a@x.test>"#)
        try expectEqual(bob.reparsed.count, 1)
        try expectEqual(bob.reparsed[0].displayName, bob.parsed.displayName)

        let backslash = try roundTripToHeader(#""a\\b" <b@x.test>"#)
        try expectEqual(backslash.parsed.displayName, #"a\b"#)
        try expectEqual(backslash.emlTo, #""a\\b" <b@x.test>"#)
        try expectEqual(backslash.reparsed.count, 1)
        try expectEqual(backslash.reparsed[0].displayName, backslash.parsed.displayName)
    },

    TestCase(name: "escaped_quote_does_not_end_quoted_string_for_comment_stripping") {
        let result = try roundTripToHeader(#""Smith \"Bob (x)\"" <a@x.test>"#)
        try expectEqual(result.parsed.displayName, #"Smith "Bob (x)""#)
        try expectEqual(result.reparsed.count, 1)
        try expectEqual(result.reparsed[0].displayName, result.parsed.displayName)
    },

    TestCase(name: "partly_quoted_display_name_round_trips") {
        let result = try roundTripToHeader(#""Doe, John" Jr <a@x.test>"#)
        try expectEqual(result.parsed.displayName, "Doe, John Jr")
        try expectEqual(result.emlTo, #""Doe, John Jr" <a@x.test>"#)
        try expectEqual(result.reparsed.count, 1)
        try expectEqual(result.reparsed[0].displayName, result.parsed.displayName)
        try expectEqual(result.reparsed[0].address, "a@x.test")
    },

    TestCase(name: "encoder_splits_between_two_byte_scalars") {
        // "ab" puts byte 45 in the middle of the 22nd e-acute.
        try expectEncodedWordsSplitBetweenScalars("ab" + String(repeating: "é", count: 30))
    },

    TestCase(name: "encoder_splits_around_four_byte_emoji") {
        // The emoji occupies bytes 43-46, straddling the 45-byte boundary.
        try expectEncodedWordsSplitBetweenScalars(String(repeating: "x", count: 42) + "😀" + " tail")
    },

    TestCase(name: "to_with_comma_display_name_round_trips_through_eml") {
        let source = try RFC822Parser.parse(Data("""
        Subject: hi
        To: "Doe, John" <j@x.test>, b@y.test
        Content-Type: text/plain

        body
        """.utf8))
        let parsed = MIMEParser.parse(source)
        try expectEqual(parsed.to.count, 2)

        let eml = EmlBuilder.buildEml(raw: source, finalRecipients: parsed, options: Options())
        let reparsed = AddressParser.parse(try headerValue("To", inEml: eml))
        try expectEqual(reparsed.count, 2)
        try expectEqual(reparsed[0].displayName, "Doe, John")
        try expectEqual(reparsed[0].address, "j@x.test")
        try expectNil(reparsed[1].displayName)
        try expectEqual(reparsed[1].address, "b@y.test")
    },

    TestCase(name: "from_with_comma_in_F_is_quoted_in_eml") {
        var opts = Options()
        opts.fromName = "Doe, John"
        opts.fromAddress = "j@x.test"
        let eml = emlWithTo([ParsedAddress(displayName: nil, address: "u@example.test")], options: opts)
        let from = try headerValue("From", inEml: eml)
        try expectEqual(from, "\"Doe, John\" <j@x.test>")
        let reparsed = AddressParser.parse(from)
        try expectEqual(reparsed.count, 1)
        try expectEqual(reparsed[0].displayName, "Doe, John")
        try expectEqual(reparsed[0].address, "j@x.test")
    },

    TestCase(name: "plain_sender_quotes_comma_display_name") {
        try expectEqual(try plainSender(fromName: "Doe, John", fromAddress: "j@x.test"), #""Doe, John" <j@x.test>"#)
    },

    TestCase(name: "each_special_forces_quoting") {
        for special in ["(", ")", "<", ">", "[", "]", ":", ";", "@", ",", "."] {
            let name = "A\(special)B"
            let to = try headerValue("To", inEml: emlWithTo([ParsedAddress(displayName: name, address: "a@x.test")]))
            try expectEqual(to, "\"\(name)\" <a@x.test>")
        }
    },

    TestCase(name: "quoted_string_escapes_backslash_and_dquote") {
        let name = #"Say "hi" \ bye"#
        let to = try headerValue("To", inEml: emlWithTo([ParsedAddress(displayName: name, address: "q@x.test")]))
        try expectEqual(to, #""Say \"hi\" \\ bye" <q@x.test>"#)
    },

    TestCase(name: "atext_display_name_stays_unquoted") {
        let name = "Build-Bot #1 O'Neil"
        let to = try headerValue("To", inEml: emlWithTo([ParsedAddress(displayName: name, address: "b@x.test")]))
        try expectEqual(to, "\(name) <b@x.test>")
    },

    TestCase(name: "non_ascii_display_name_is_rfc2047_encoded_in_eml") {
        let name = "Zoë Ünïcode, Ltd"
        let to = try headerValue("To", inEml: emlWithTo([ParsedAddress(displayName: name, address: "z@x.test")]))
        try expect(to.unicodeScalars.allSatisfy(\.isASCII), "To header must be pure ASCII, got \(to)")
        try expect(to.hasPrefix("=?UTF-8?B?"), "expected an encoded-word, got \(to)")
        let reparsed = AddressParser.parse(to)
        try expectEqual(reparsed.count, 1)
        try expectEqual(reparsed[0].displayName, name)
        try expectEqual(reparsed[0].address, "z@x.test")
    },

    TestCase(name: "long_non_ascii_display_name_splits_into_short_encoded_words") {
        let name = String(repeating: "Ünïcödé ", count: 12) + "end"
        let to = try headerValue("To", inEml: emlWithTo([ParsedAddress(displayName: name, address: "l@x.test")]))
        let encodedWords = to.split(separator: " ").filter { $0.hasPrefix("=?") }
        try expect(encodedWords.count > 1, "expected several encoded-words, got \(to)")
        try expect(encodedWords.allSatisfy { $0.count <= 75 }, "encoded-word over 75 chars in \(to)")
        let reparsed = AddressParser.parse(to)
        try expectEqual(reparsed.count, 1)
        try expectEqual(reparsed[0].displayName, name)
    },

    TestCase(name: "plain_sender_keeps_non_ascii_literal") {
        try expectEqual(try plainSender(fromName: "Zoë", fromAddress: "z@x.test"), "Zoë <z@x.test>")
        let withComma = try plainSender(fromName: "Zoë, Ann", fromAddress: "z@x.test")
        try expectEqual(withComma, #""Zoë, Ann" <z@x.test>"#)
        try expect(withComma?.contains("=?UTF-8?") == false, "the sender must not be RFC 2047 encoded")
    },
])
