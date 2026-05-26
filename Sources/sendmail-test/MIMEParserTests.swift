import Foundation
import SendmailCore

let mimeTests = TestSuite(name: "MIMEParser", cases: [
    TestCase(name: "simple_text_plain") {
        let input = "Subject: Hi\nContent-Type: text/plain; charset=utf-8\n\nHello.\n"
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expectEqual(msg.subject, "Hi")
        try expectEqual(msg.body, "Hello.\n")
        try expect(msg.attachments.isEmpty)
    },

    TestCase(name: "quoted_printable_body") {
        let input = """
        Subject: QP
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        caf=C3=A9 is good
        """
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expectEqual(msg.body, "café is good")
    },

    TestCase(name: "base64_body") {
        let input = """
        Subject: B64
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: base64

        SGVsbG8K
        """
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expectEqual(msg.body, "Hello\n")
    },

    TestCase(name: "multipart_with_attachment") {
        let input = """
        To: a@x.com
        Subject: with attachment
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="BOUND"

        --BOUND
        Content-Type: text/plain; charset=utf-8

        Body part text.
        --BOUND
        Content-Type: application/octet-stream; name="data.bin"
        Content-Disposition: attachment; filename="data.bin"
        Content-Transfer-Encoding: base64

        SGVsbG8K
        --BOUND--
        """
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expectEqual(msg.body, "Body part text.")
        try expectEqual(msg.attachments.count, 1)
        try expectEqual(msg.attachments[0].filename, "data.bin")
        try expectEqual(msg.attachments[0].contentType, "application/octet-stream")
        try expectEqual(msg.attachments[0].data, Data("Hello\n".utf8))
    },

    TestCase(name: "subject_encoded_word_decoded") {
        let input = "Subject: =?UTF-8?B?SGVsbG8=?=\nContent-Type: text/plain\n\nbody"
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expectEqual(msg.subject, "Hello")
    },

    TestCase(name: "to_cc_bcc_collected") {
        let input = """
        To: a@x, "Bob B" <b@y>
        Cc: c@z
        Bcc: d@w
        Subject: recipients
        Content-Type: text/plain

        body
        """
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expectEqual(msg.to.count, 2)
        try expectEqual(msg.to[0].address, "a@x")
        try expectEqual(msg.to[1].displayName, "Bob B")
        try expectEqual(msg.to[1].address, "b@y")
        try expectEqual(msg.cc.first?.address, "c@z")
        try expectEqual(msg.bcc.first?.address, "d@w")
    },

    TestCase(name: "html_only_body_stripped_to_text") {
        let input = """
        Subject: html
        Content-Type: text/html; charset=utf-8

        <html><body><p>Hi&nbsp;there</p></body></html>
        """
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expect(msg.body.contains("Hi"))
        try expect(msg.body.contains("there"))
        try expect(!msg.body.contains("<p>"))
    },

    TestCase(name: "html_body_preserved_alongside_plain_text") {
        // The parser should keep both the stripped plain-text body (fallback)
        // and the raw HTML in htmlBody (for the rich-HTML render path).
        let input = """
        Subject: dual
        Content-Type: multipart/alternative; boundary="ALT"

        --ALT
        Content-Type: text/plain; charset=utf-8

        plain body
        --ALT
        Content-Type: text/html; charset=utf-8

        <html><body><p>html body</p></body></html>
        --ALT--
        """
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expectEqual(msg.body, "plain body")
        try expectNotNil(msg.htmlBody)
        try expect(msg.htmlBody!.contains("<p>html body</p>"))
    },

    TestCase(name: "html_only_message_populates_both_body_and_htmlBody") {
        let input = "Subject: html\nContent-Type: text/html; charset=utf-8\n\n<p>only</p>"
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expectEqual(msg.body, "only")
        try expectEqual(msg.htmlBody, "<p>only</p>")
    },

    TestCase(name: "plain_only_message_leaves_htmlBody_nil") {
        let input = "Subject: plain\nContent-Type: text/plain\n\njust text"
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expectEqual(msg.body, "just text")
        try expectNil(msg.htmlBody)
    },

    TestCase(name: "html_style_block_contents_dropped") {
        // Regression: an HTML email with a <style> block in <head> must not
        // dump CSS rules into the plain-text fallback.
        let input = """
        Subject: styled
        Content-Type: text/html; charset=utf-8

        <html>
        <head>
        <style>
        pre { padding: 0.3em; background: #F0F0F0; }
        table td { border-color: #dbdbdb; }
        </style>
        </head>
        <body>
        <p>test1</p>
        </body>
        </html>
        """
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expect(!msg.body.contains("padding"), "CSS leaked into body: \(msg.body)")
        try expect(!msg.body.contains("border-color"), "CSS leaked into body: \(msg.body)")
        try expect(msg.body.contains("test1"))
    },

    TestCase(name: "multipart_alternative_empty_plain_falls_back_to_html") {
        // Regression for email-output style: text/plain part is empty (or
        // whitespace only), so the parser must use the text/html part's
        // stripped text content as the body.
        let input = """
        Subject: empty plain fallback
        Content-Type: multipart/alternative; boundary="ALT"

        --ALT
        Content-Type: text/plain; charset=utf-8



        --ALT
        Content-Type: text/html; charset=utf-8

        <html><head><style>p { color: red; }</style></head><body><p>fallback text</p></body></html>
        --ALT--
        """
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expect(msg.body.contains("fallback text"))
        try expect(!msg.body.contains("color: red"))
    },

    TestCase(name: "html_paragraphs_become_newline_separated") {
        let html = "<html><body><p>one</p><p>two</p><p>three</p></body></html>"
        let input = "Subject: paras\nContent-Type: text/html\n\n\(html)"
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expectEqual(msg.body, "one\ntwo\nthree")
    },

    TestCase(name: "multipart_alternative_picks_text_plain") {
        let input = """
        Subject: alt
        Content-Type: multipart/alternative; boundary="ALT"

        --ALT
        Content-Type: text/plain; charset=utf-8

        plain version
        --ALT
        Content-Type: text/html; charset=utf-8

        <p>html version</p>
        --ALT--
        """
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expectEqual(msg.body, "plain version")
    },
])
