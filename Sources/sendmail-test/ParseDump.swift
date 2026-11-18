import Foundation
import SendmailCore

/// `sendmail-test --parse-dump FILE...` prints one JSON object mapping each
/// FILE to SendmailCore's parse of it, for the differential check in
/// tests/conformance/. Lives in the test target so the shipped binary has no
/// dump mode.
enum ParseDump {
    static func run(paths: [String]) -> Int32 {
        var dump: [String: Any] = [:]
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path) else {
                FileHandle.standardError.write(Data("parse-dump: cannot read \(path)\n".utf8))
                return 1
            }
            do {
                dump[path] = try describe(data)
            } catch {
                dump[path] = ["error": "\(error)"]
            }
        }
        do {
            let json = try JSONSerialization.data(withJSONObject: dump, options: [.sortedKeys, .prettyPrinted])
            FileHandle.standardOutput.write(json)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("parse-dump: \(error)\n".utf8))
            return 1
        }
    }

    private static func describe(_ data: Data) throws -> [String: Any] {
        let raw = try RFC822Parser.parse(data)
        let message = MIMEParser.parse(raw)
        let rebuiltEml = EmlBuilder.buildEml(raw: raw, finalRecipients: message, options: Options())
        return [
            "subject": message.subject,
            "from": message.from.map(describe) ?? NSNull(),
            "to": message.to.map(describe),
            "cc": message.cc.map(describe),
            "bcc": message.bcc.map(describe),
            "body": message.body,
            "html": message.htmlBody ?? NSNull(),
            "attachments": message.attachments.map { attachment in
                [
                    "filename": attachment.filename,
                    "contentType": attachment.contentType,
                    "base64": attachment.data.base64EncodedString(),
                ]
            },
            "rebuiltEmlBase64": rebuiltEml.base64EncodedString(),
        ]
    }

    private static func describe(_ address: ParsedAddress) -> [String: Any] {
        ["name": address.displayName ?? NSNull(), "address": address.address]
    }
}
