import Foundation
import SendmailCore

let rfc822Tests = TestSuite(name: "RFC822Parser", cases: [
    TestCase(name: "simple_headers_and_body") {
        let input = "Subject: Hello\nFrom: a@x.com\n\nBody line.\n"
        let raw = try RFC822Parser.parse(Data(input.utf8))
        try expectEqual(raw.value(for: "subject"), "Hello")
        try expectEqual(raw.value(for: "From"), "a@x.com")
        try expectEqual(String(decoding: raw.body, as: UTF8.self), "Body line.\n")
    },

    TestCase(name: "case_insensitive_lookup") {
        let input = "SUBJECT: Hi\n\nBody.\n"
        let raw = try RFC822Parser.parse(Data(input.utf8))
        try expectEqual(raw.value(for: "subject"), "Hi")
        try expectEqual(raw.value(for: "Subject"), "Hi")
    },

    TestCase(name: "crlf_separator") {
        let input = "Subject: A\r\nFrom: b@x\r\n\r\nbody\r\n"
        let raw = try RFC822Parser.parse(Data(input.utf8))
        try expectEqual(raw.value(for: "subject"), "A")
        try expectEqual(String(decoding: raw.body, as: UTF8.self), "body\r\n")
    },

    TestCase(name: "folded_header") {
        let input = "Subject: line one\n continuation line\n\nbody\n"
        let raw = try RFC822Parser.parse(Data(input.utf8))
        try expectEqual(raw.value(for: "subject"), "line one continuation line")
    },

    // RFC 5322 2.2.3: unfolding removes only the CRLF; the WSP that starts the
    // continuation line stays, whether it is a tab or several spaces.
    TestCase(name: "unfolding_keeps_folding_whitespace") {
        let input = "Subject: line one\r\n\tafter a tab\r\nX-Spaced: a\r\n   b\r\n\r\nbody\r\n"
        let raw = try RFC822Parser.parse(Data(input.utf8))
        try expectEqual(raw.value(for: "subject"), "line one\tafter a tab")
        try expectEqual(raw.value(for: "x-spaced"), "a   b")
    },

    TestCase(name: "multiple_To_headers_collected") {
        let input = "To: a@x\nTo: b@x\n\nbody\n"
        let raw = try RFC822Parser.parse(Data(input.utf8))
        try expectEqual(raw.values(for: "to"), ["a@x", "b@x"])
    },

    TestCase(name: "structured_parse_extracts_params") {
        let (main, params) = RFC822Parser.parseStructured("multipart/mixed; boundary=\"abc\"; charset=utf-8")
        try expectEqual(main, "multipart/mixed")
        try expectEqual(params["boundary"], "abc")
        try expectEqual(params["charset"], "utf-8")
    },

    TestCase(name: "structured_parse_handles_quoted_semicolons") {
        let (main, params) = RFC822Parser.parseStructured("text/plain; name=\"weird;name.txt\"")
        try expectEqual(main, "text/plain")
        try expectEqual(params["name"], "weird;name.txt")
    },

    TestCase(name: "no_blank_line_treats_as_headers_only") {
        let input = "Subject: only-headers\n"
        let raw = try RFC822Parser.parse(Data(input.utf8))
        try expectEqual(raw.value(for: "subject"), "only-headers")
        try expectEqual(raw.body, Data())
    },
])
