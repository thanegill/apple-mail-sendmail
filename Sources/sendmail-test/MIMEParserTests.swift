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
        //
        // Regression: an older code path classified the text/html part as a
        // phantom attachment whenever text/plain had already filled the body
        // slot, producing an `att-NN-attachment-N.bin` in the compose window.
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
        try expect(msg.attachments.isEmpty, "text/html sibling must not be promoted to an attachment")
    },

    TestCase(name: "multipart_mixed_wrapper_with_no_attachments") {
        // email-output structure: outer multipart/mixed exists for potential
        // attachments, but when no --attach is given the wrapper contains only
        // the inner multipart/alternative body. The parser must not see this
        // outer wrapper as a signal that attachments exist.
        let input = """
        Subject: wrapped
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="OUTER"

        --OUTER
        Content-Type: multipart/alternative; boundary="INNER"

        --INNER
        Content-Type: text/plain; charset=utf-8



        --INNER
        Content-Type: text/html; charset=utf-8

        <html><head><style>p { color: red; }</style></head><body><p>hello</p></body></html>
        --INNER--
        --OUTER--
        """
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expect(msg.attachments.isEmpty, "outer multipart/mixed wrapper must not count as an attachment")
        try expectNotNil(msg.htmlBody)
        try expect(msg.htmlBody!.contains("<p>hello</p>"))
        try expect(msg.body.contains("hello"))
        try expect(!msg.body.contains("color: red"), "CSS leaked into body: \(msg.body)")
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

    TestCase(name: "inline_related_image_not_promoted_to_attachment") {
        // Issue #17: a multipart/related inline image (Content-Disposition:
        // inline, image/png, no filename, referenced by CID) must NOT become a
        // phantom attachment. A genuine attachment sibling (disposition
        // attachment with a filename) still must.
        let input = """
        Subject: related
        MIME-Version: 1.0
        Content-Type: multipart/related; boundary="REL"

        --REL
        Content-Type: text/html; charset=utf-8

        <html><body><p>see <img src="cid:img1"></p></body></html>
        --REL
        Content-Type: image/png
        Content-Disposition: inline
        Content-ID: <img1>
        Content-Transfer-Encoding: base64

        SGVsbG8K
        --REL
        Content-Type: application/pdf; name="x.pdf"
        Content-Disposition: attachment; filename="x.pdf"
        Content-Transfer-Encoding: base64

        SGVsbG8K
        --REL--
        """
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expect(msg.attachments.count == 1, "inline image must not be promoted to an attachment")
        try expectEqual(msg.attachments[0].filename, "x.pdf")
        try expectEqual(msg.attachments[0].contentType, "application/pdf")
        try expectNotNil(msg.htmlBody)
    },

    TestCase(name: "stripHTML_does_not_double_decode_escaped_entity") {
        // Issue #18: `&amp;lt;` must decode to the literal `&lt;`, not `<`.
        // The old chained-replace turned `&amp;` into `&` first, then the
        // resulting `&lt;` into `<`.
        let input = "Subject: e\nContent-Type: text/html; charset=utf-8\n\n<p>&amp;lt;</p>"
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expectEqual(msg.body, "&lt;")
    },

    TestCase(name: "stripHTML_decodes_numeric_and_hex_references") {
        // Issue #18: decimal `&#8217;` and hex `&#x2019;` both decode to the
        // right-single-quotation-mark glyph (U+2019).
        let rsquo = "\u{2019}"
        let dec = "Subject: e\nContent-Type: text/html; charset=utf-8\n\n<p>it&#8217;s</p>"
        let msgDec = MIMEParser.parse(try RFC822Parser.parse(Data(dec.utf8)))
        try expectEqual(msgDec.body, "it\(rsquo)s")

        let hex = "Subject: e\nContent-Type: text/html; charset=utf-8\n\n<p>it&#x2019;s</p>"
        let msgHex = MIMEParser.parse(try RFC822Parser.parse(Data(hex.utf8)))
        try expectEqual(msgHex.body, "it\(rsquo)s")
    },

    TestCase(name: "stripHTML_basic_tag_and_entity_mix") {
        // Issue #18: a mix of tags and named entities renders correctly.
        let input = """
        Subject: mix
        Content-Type: text/html; charset=utf-8

        <p>Tom &amp; Jerry say &lt;hi&gt; &quot;now&quot;</p>
        """
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expectEqual(msg.body, "Tom & Jerry say <hi> \"now\"")
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
