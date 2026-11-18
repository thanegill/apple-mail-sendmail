import Foundation
import SendmailCore

private func attachmentFilenames(contentDisposition: String) throws -> [String] {
    let input = """
    Subject: 2231
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="BOUND"

    --BOUND
    Content-Type: text/plain; charset=utf-8

    Body.
    --BOUND
    Content-Type: application/pdf
    Content-Disposition: \(contentDisposition)

    x
    --BOUND--
    """
    return MIMEParser.parse(try RFC822Parser.parse(Data(input.utf8))).attachments.map(\.filename)
}

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

    TestCase(name: "quoted_printable_lowercase_hex") {
        // The shared hexNibble decoder must accept lowercase hex digits;
        // =c3=a9 is the same "é" byte pair as the uppercase =C3=A9 form.
        let input = """
        Subject: QP
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        caf=c3=a9 is good
        """
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expectEqual(msg.body, "café is good")
    },

    TestCase(name: "quoted_printable_invalid_hex_kept_literal") {
        // A '=' not followed by two hex digits is not an escape; the shared
        // hexNibble decoder returns nil and the bytes pass through verbatim.
        let input = """
        Subject: QP
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        a=ZZb
        """
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expectEqual(msg.body, "a=ZZb")
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

    TestCase(name: "from_header_first_mailbox_collected") {
        let input = """
        From: "Work Bot" <work@example.test>, other@example.test
        To: a@example.test
        Content-Type: text/plain

        body
        """
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expectEqual(msg.from?.displayName, "Work Bot")
        try expectEqual(msg.from?.address, "work@example.test")
    },

    TestCase(name: "from_header_encoded_word_display_name_decoded") {
        let input = "From: =?UTF-8?B?QsO8cm8gQm90?= <work@example.test>\nContent-Type: text/plain\n\nbody"
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expectEqual(msg.from?.displayName, "Büro Bot")
        try expectEqual(msg.from?.address, "work@example.test")
    },

    TestCase(name: "missing_from_header_leaves_from_nil") {
        let input = "To: a@example.test\nContent-Type: text/plain\n\nbody"
        let raw = try RFC822Parser.parse(Data(input.utf8))
        let msg = MIMEParser.parse(raw)
        try expectNil(msg.from)
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

    TestCase(name: "attachment_filename_preserves_case") {
        let input = """
        Subject: case
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="BOUND"

        --BOUND
        Content-Type: text/plain; charset=utf-8

        Body.
        --BOUND
        Content-Type: application/pdf
        Content-Disposition: attachment; filename="Report-Q3.PDF"
        Content-Transfer-Encoding: base64

        SGVsbG8K
        --BOUND--
        """
        let msg = MIMEParser.parse(try RFC822Parser.parse(Data(input.utf8)))
        try expectEqual(msg.attachments.count, 1)
        try expectEqual(msg.attachments[0].filename, "Report-Q3.PDF")
    },

    TestCase(name: "attachment_filename_encoded_word_decoded") {
        // The base64 payload of the encoded-word is case-sensitive; "w6l0w6kucGRm"
        // is the UTF-8 bytes of "\u{E9}t\u{E9}.pdf".
        let input = """
        Subject: ew
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="BOUND"

        --BOUND
        Content-Type: text/plain; charset=utf-8

        Body.
        --BOUND
        Content-Type: application/pdf
        Content-Disposition: attachment; filename="=?UTF-8?B?w6l0w6kucGRm?="
        Content-Transfer-Encoding: base64

        SGVsbG8K
        --BOUND--
        """
        let msg = MIMEParser.parse(try RFC822Parser.parse(Data(input.utf8)))
        try expectEqual(msg.attachments.count, 1)
        try expectEqual(msg.attachments[0].filename, "\u{E9}t\u{E9}.pdf")
    },

    TestCase(name: "uppercase_disposition_type_and_param_name") {
        // The disposition type and parameter names are case-insensitive
        // (RFC 2183): a bare ATTACHMENT on a text part must still be an
        // attachment, and an INLINE image without a name must still be skipped.
        let input = """
        Subject: upper
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="BOUND"

        --BOUND
        Content-Type: text/plain; charset=utf-8

        Body.
        --BOUND
        Content-Type: text/plain; charset=utf-8
        Content-Disposition: ATTACHMENT

        attached text
        --BOUND
        Content-Type: text/csv
        Content-Disposition: ATTACHMENT; Filename="Notes.CSV"

        a,b
        --BOUND
        Content-Type: image/png
        Content-Disposition: INLINE
        Content-Transfer-Encoding: base64

        SGVsbG8K
        --BOUND--
        """
        let msg = MIMEParser.parse(try RFC822Parser.parse(Data(input.utf8)))
        try expectEqual(msg.body, "Body.")
        try expectEqual(msg.attachments.map(\.filename), ["attachment-1.bin", "Notes.CSV"])
    },

    TestCase(name: "rfc2231_extended_filename_preferred_over_plain") {
        let input = """
        Subject: 2231
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="BOUND"

        --BOUND
        Content-Type: text/plain; charset=utf-8

        Body.
        --BOUND
        Content-Type: application/pdf
        Content-Disposition: attachment; filename="ete.pdf"; filename*=UTF-8''%C3%A9t%C3%A9.pdf

        x
        --BOUND--
        """
        let msg = MIMEParser.parse(try RFC822Parser.parse(Data(input.utf8)))
        try expectEqual(msg.attachments.map(\.filename), ["\u{E9}t\u{E9}.pdf"])
    },

    TestCase(name: "rfc2231_content_type_name_with_charset_and_language") {
        // No Content-Disposition: the name* parameter alone identifies the
        // attachment, in a non-UTF-8 charset with a language tag.
        let input = """
        Subject: 2231
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="BOUND"

        --BOUND
        Content-Type: text/plain; charset=utf-8

        Body.
        --BOUND
        Content-Type: text/plain; name*=iso-8859-1'fr'R%E9sum%E9.txt

        x
        --BOUND--
        """
        let msg = MIMEParser.parse(try RFC822Parser.parse(Data(input.utf8)))
        try expectEqual(msg.body, "Body.")
        try expectEqual(msg.attachments.map(\.filename), ["R\u{E9}sum\u{E9}.txt"])
    },

    TestCase(name: "rfc2231_filename_continuations") {
        // Encoded (*N*) and literal (*N) segments are joined in index order;
        // only segment 0 carries the charset prefix.
        let input = """
        Subject: 2231
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="BOUND"

        --BOUND
        Content-Type: text/plain; charset=utf-8

        Body.
        --BOUND
        Content-Type: application/pdf
        Content-Disposition: attachment; filename*1*=%C3%A9-Long; filename*0*=UTF-8''%C3%A9t; filename*2=" Name.pdf"

        x
        --BOUND--
        """
        let msg = MIMEParser.parse(try RFC822Parser.parse(Data(input.utf8)))
        try expectEqual(msg.attachments.map(\.filename), ["\u{E9}t\u{E9}-Long Name.pdf"])
    },

    TestCase(name: "rfc2231_literal_continuations_rfc2047_decoded") {
        try expectEqual(
            try attachmentFilenames(contentDisposition: #"attachment; filename*0="=?UTF-8?B?w6l0"; filename*1="w6kucGRm?=""#),
            ["\u{E9}t\u{E9}.pdf"]
        )
        try expectEqual(
            try attachmentFilenames(contentDisposition: #"attachment; filename*0="=?UTF-8?B?w6l0w6kucGRm?=""#),
            ["\u{E9}t\u{E9}.pdf"]
        )
    },

    // RFC 2231 sections 3, 4 and 4.1, with the examples' `title` and `URL`
    // parameters renamed to `filename`.
    TestCase(name: "rfc2231_section_examples") {
        try expectEqual(
            try attachmentFilenames(contentDisposition: #"attachment; filename*0="ftp://"; filename*1="cs.utk.edu/pub/moore/bulk-mailer/bulk-mailer.tar""#),
            ["ftp://cs.utk.edu/pub/moore/bulk-mailer/bulk-mailer.tar"]
        )
        try expectEqual(
            try attachmentFilenames(contentDisposition: "attachment; filename*=us-ascii'en-us'This%20is%20%2A%2A%2Afun%2A%2A%2A"),
            ["This is ***fun***"]
        )
        try expectEqual(
            try attachmentFilenames(contentDisposition: #"attachment; filename*0*=us-ascii'en'This%20is%20even%20more%20; filename*1*=%2A%2A%2Afun%2A%2A%2A%20; filename*2="isn't it!""#),
            ["This is even more ***fun*** isn't it!"]
        )
    },

    // RFC 2045 section 5.1: `charset=us-ascii (Plain text)` carries a comment
    // after the value.
    TestCase(name: "rfc2045_charset_followed_by_comment") {
        let input = "Content-Type: text/plain; charset=iso-8859-1 (Latin text)\nContent-Transfer-Encoding: quoted-printable\n\ncaf=E9"
        let msg = MIMEParser.parse(try RFC822Parser.parse(Data(input.utf8)))
        try expectEqual(msg.body, "caf\u{E9}")
    },

    // RFC 2046 section 5.1.1's sample message: a preamble, a body part with no
    // header fields (implicitly typed US-ASCII text), and an epilogue.
    TestCase(name: "rfc2046_sec5_1_1_sample_with_headerless_part") {
        let input = """
        From: Nathaniel Borenstein <nsb@bellcore.com>
        To: Ned Freed <ned@innosoft.com>
        Date: Sun, 21 Mar 1993 23:56:48 -0800 (PST)
        Subject: Sample message
        MIME-Version: 1.0
        Content-type: multipart/mixed; boundary="simple boundary"

        This is the preamble.  It is to be ignored, though it
        is a handy place for composition agents to include an
        explanatory note to non-MIME conformant readers.

        --simple boundary

        This is implicitly typed plain US-ASCII text.
        It does NOT end with a linebreak.
        --simple boundary
        Content-type: text/plain; charset=us-ascii

        This is explicitly typed plain US-ASCII text.
        It DOES end with a linebreak.

        --simple boundary--

        This is the epilogue.  It is also to be ignored.
        """
        let msg = MIMEParser.parse(try RFC822Parser.parse(Data(input.utf8)))
        try expectEqual(msg.body, "This is implicitly typed plain US-ASCII text.\nIt does NOT end with a linebreak.")
        try expect(msg.attachments.isEmpty)
    },

    TestCase(name: "only_the_line_break_before_a_delimiter_is_dropped") {
        for lineBreak in ["\n", "\r\n"] {
            let input = [
                "Content-Type: multipart/mixed; boundary=\"B\"",
                "",
                "--B",
                "Content-Type: text/plain; charset=utf-8",
                "",
                "Body.",
                "",
                "",
                "--B",
                "Content-Type: text/plain",
                "Content-Disposition: attachment; filename=\"notes.txt\"",
                "",
                "line one",
                "",
                "--B--",
                "",
            ].joined(separator: lineBreak)
            let msg = MIMEParser.parse(try RFC822Parser.parse(Data(input.utf8)))
            try expectEqual(msg.body, "Body.\(lineBreak)\(lineBreak)")
            try expectEqual(msg.attachments.map(\.data), [Data("line one\(lineBreak)".utf8)])
        }
    },

    // RFC 2046 section 5.1.5: in multipart/digest a part without Content-Type
    // is message/rfc822, so the digested messages are not read as body text.
    TestCase(name: "rfc2046_digest_parts_default_to_message_rfc822") {
        let input = """
        Subject: Internet Digest, volume 42
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="---- main boundary ----"

        ------ main boundary ----

        ...Introductory text or table of contents...

        ------ main boundary ----
        Content-Type: multipart/digest; boundary="---- next message ----"

        ------ next message ----

        From: someone-else
        Subject: my opinion

        ...body goes here ...

        ------ next message ----
        Content-Type: text/plain

        typed explicitly
        ------ next message ------

        ------ main boundary ------
        """
        let msg = MIMEParser.parse(try RFC822Parser.parse(Data(input.utf8)))
        try expectEqual(msg.body, "...Introductory text or table of contents...\n")
        try expectEqual(msg.attachments.map(\.contentType), ["message/rfc822"])
        try expect(String(decoding: msg.attachments[0].data, as: UTF8.self).hasPrefix("From: someone-else\n"))
    },

    // RFC 2231 applies to every parameter, not just filenames: boundary*= and
    // charset*= (as CPython's test_email msg_33 sends them).
    TestCase(name: "rfc2231_extended_boundary_and_charset") {
        let input = """
        Content-Type: multipart/signed; micalg*=ansi-x3.4-1968''pgp-md5;
        \tboundary*="ansi-x3.4-1968''EeQfGwPcQSOJBaQU"

        --EeQfGwPcQSOJBaQU
        Content-Type: text/plain; charset*=us-ascii''iso-8859-1
        Content-Transfer-Encoding: quoted-printable

        caf=E9
        --EeQfGwPcQSOJBaQU--
        """
        let msg = MIMEParser.parse(try RFC822Parser.parse(Data(input.utf8)))
        try expectEqual(msg.body, "caf\u{E9}")
    },

    TestCase(name: "rfc2231_continuation_gap_stops_joining") {
        try expectEqual(
            try attachmentFilenames(contentDisposition: "attachment; filename*0*=UTF-8''a; filename*2*=c"),
            ["a"]
        )
    },

    TestCase(name: "rfc2231_malformed_percent_escapes_kept_literal") {
        try expectEqual(
            try attachmentFilenames(contentDisposition: "attachment; filename*=UTF-8''a%ZZb%"),
            ["a%ZZb%"]
        )
        try expectEqual(
            try attachmentFilenames(contentDisposition: "attachment; filename*=UTF-8''a%4"),
            ["a%4"]
        )
    },

    TestCase(name: "rfc2231_extended_preferred_over_continuations") {
        try expectEqual(
            try attachmentFilenames(contentDisposition: "attachment; filename*0*=UTF-8''cont.pdf; filename*=UTF-8''whole.pdf"),
            ["whole.pdf"]
        )
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
