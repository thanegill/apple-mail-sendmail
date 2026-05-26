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
])
