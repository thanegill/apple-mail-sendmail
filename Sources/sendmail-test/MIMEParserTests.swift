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
