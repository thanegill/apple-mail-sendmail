import Foundation
import SendmailCore

let encodedWordTests = TestSuite(name: "EncodedWord", cases: [
    TestCase(name: "passthrough_when_no_encoded_word") {
        try expectEqual(EncodedWord.decode("plain text"), "plain text")
    },

    TestCase(name: "base64_utf8") {
        try expectEqual(EncodedWord.decode("=?UTF-8?B?aGVsbG8gd29ybGQ=?="), "hello world")
    },

    TestCase(name: "base64_utf8_emoji") {
        try expectEqual(EncodedWord.decode("=?UTF-8?B?aGVsbG8g8J+Riw==?="), "hello 👋")
    },

    TestCase(name: "q_encoding_underscore_is_space") {
        try expectEqual(EncodedWord.decode("=?UTF-8?Q?Hello_World?="), "Hello World")
    },

    TestCase(name: "q_encoding_hex_byte_utf8") {
        try expectEqual(EncodedWord.decode("=?UTF-8?Q?caf=C3=A9?="), "café")
    },

    TestCase(name: "q_encoding_lowercase_hex_byte") {
        // The shared hexNibble decoder must accept lowercase hex digits in the
        // Q-encoding path; =c3=a9 decodes to the same "é" as uppercase.
        try expectEqual(EncodedWord.decode("=?UTF-8?Q?caf=c3=a9?="), "café")
    },

    TestCase(name: "iso_8859_1_q_encoding") {
        try expectEqual(EncodedWord.decode("=?ISO-8859-1?Q?caf=E9?="), "café")
    },

    TestCase(name: "adjacent_encoded_words_whitespace_dropped") {
        try expectEqual(
            EncodedWord.decode("=?UTF-8?B?SGVsbG8=?= =?UTF-8?B?d29ybGQ=?="),
            "Helloworld"
        )
    },

    TestCase(name: "mixed_plain_and_encoded") {
        try expectEqual(
            EncodedWord.decode("prefix =?UTF-8?B?bWlkZGxl?= suffix"),
            "prefix middle suffix"
        )
    },

    // Issue #11: windows-1252 bytes 0x80-0x9F carry printable glyphs (curly
    // quotes, euro sign), not the C1 control chars ISO-8859-1 has there.
    TestCase(name: "windows_1252_curly_quotes") {
        // 0x93 -> U+201C (left double quote), 0x94 -> U+201D (right double quote).
        try expectEqual(
            EncodedWord.decode("=?windows-1252?Q?=93hi=94?="),
            "\u{201C}hi\u{201D}"
        )
    },

    TestCase(name: "windows_1252_euro_sign") {
        // 0x80 -> U+20AC (euro sign) in cp1252; a C1 control char in Latin-1.
        try expectEqual(
            EncodedWord.decode("=?cp1252?Q?=80?="),
            "\u{20AC}"
        )
    },

    // RFC 2047 section 8: the header examples.
    TestCase(name: "rfc2047_sec8_header_examples") {
        try expectEqual(EncodedWord.decode("=?US-ASCII?Q?Keith_Moore?="), "Keith Moore")
        try expectEqual(EncodedWord.decode("=?ISO-8859-1?Q?Keld_J=F8rn_Simonsen?="), "Keld J\u{F8}rn Simonsen")
        try expectEqual(EncodedWord.decode("=?ISO-8859-1?Q?Andr=E9?= Pirard"), "Andr\u{E9} Pirard")
        try expectEqual(
            EncodedWord.decode("=?ISO-8859-1?B?SWYgeW91IGNhbiByZWFkIHRoaXMgeW8=?= =?ISO-8859-2?B?dSB1bmRlcnN0YW5kIHRoZSBleGFtcGxlLg==?="),
            "If you can read this you understand the example."
        )
        try expectEqual(EncodedWord.decode("=?ISO-8859-1?Q?Olle_J=E4rnefors?="), "Olle J\u{E4}rnefors")
        try expectEqual(EncodedWord.decode("=?ISO-8859-1?Q?Patrik_F=E4ltstr=F6m?="), "Patrik F\u{E4}ltstr\u{F6}m")
        // ISO-8859-8 Hebrew, in the logical order the octets carry.
        try expectEqual(
            EncodedWord.decode("=?iso-8859-8?b?7eXs+SDv4SDp7Oj08A==?="),
            "\u{05DD}\u{05D5}\u{05DC}\u{05E9} \u{05DF}\u{05D1} \u{05D9}\u{05DC}\u{05D8}\u{05E4}\u{05E0}"
        )
    },

    // RFC 2047 section 8: the "encoded form -> displayed as" table.
    TestCase(name: "rfc2047_sec8_display_table") {
        let table: [(String, String)] = [
            ("(=?ISO-8859-1?Q?a?=)", "(a)"),
            ("(=?ISO-8859-1?Q?a?= b)", "(a b)"),
            ("(=?ISO-8859-1?Q?a?= =?ISO-8859-1?Q?b?=)", "(ab)"),
            ("(=?ISO-8859-1?Q?a?=  =?ISO-8859-1?Q?b?=)", "(ab)"),
            ("(=?ISO-8859-1?Q?a?=\r\n    =?ISO-8859-1?Q?b?=)", "(ab)"),
            ("(=?ISO-8859-1?Q?a_b?=)", "(a b)"),
            ("(=?ISO-8859-1?Q?a?= =?ISO-8859-2?Q?_b?=)", "(a b)"),
        ]
        for (encoded, displayed) in table {
            let unfolded = encoded.replacingOccurrences(of: "\r\n", with: "")
            try expect(EncodedWord.decode(unfolded) == displayed, "\(encoded) decoded to \(EncodedWord.decode(unfolded)), want \(displayed)")
        }
    },

    // RFC 2231 section 5: an encoded-word charset may carry a "*language" suffix.
    TestCase(name: "rfc2231_sec5_charset_language_suffix") {
        try expectEqual(EncodedWord.decode("=?US-ASCII*EN?Q?Keith_Moore?="), "Keith Moore")
        try expectEqual(EncodedWord.decode("=?ISO-8859-1*fr?Q?caf=E9?="), "caf\u{E9}")
    },

    // Issue #15: a single invalid UTF-8 byte must not blank the whole value.
    // Strict decode returns nil (coalesced to "" by callers); the lossy fallback
    // substitutes U+FFFD and preserves the surrounding text.
    TestCase(name: "utf8_invalid_byte_falls_back_lossy") {
        // 0xA9 is a stray high byte, invalid as standalone UTF-8.
        let decoded = EncodedWord.decode("=?UTF-8?Q?caf=A9?=")
        try expect(!decoded.isEmpty, "invalid-byte utf-8 decode should not be empty")
        try expect(decoded.hasPrefix("caf"), "surrounding ascii text should survive")
    },
])
