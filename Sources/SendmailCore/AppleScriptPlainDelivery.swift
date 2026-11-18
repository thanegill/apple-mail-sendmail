import Foundation

public typealias ScriptRunner = (String) throws -> Void

/// The plain path by generated AppleScript, handed to a `ScriptRunner`
/// (`AppleScript.run` by default; tests and the dry run record or print the
/// script instead).
public struct AppleScriptPlainDelivery: PlainDelivery {
    /// Where the body file its script reads is staged.
    let staging: TempDir
    let runner: ScriptRunner

    public init(staging: TempDir, runner: @escaping ScriptRunner = { try AppleScript.run($0) }) {
        self.staging = staging
        self.runner = runner
    }

    public func deliverPlain(_ compose: PlainCompose) throws {
        let bodyURL = try staging.write(Data(compose.body.utf8), name: "body.txt")
        try runner(Self.buildClassicScript(
            subject: compose.subject,
            sender: compose.sender,
            visible: !compose.send,
            bodyPath: bodyURL.path,
            to: compose.to,
            cc: compose.cc,
            bcc: compose.bcc,
            attachmentPaths: compose.attachmentURLs.map { $0.path },
            send: compose.send
        ))
    }

    // MARK: - Classic script (plain-text path)

    private static func buildClassicScript(
        subject: String,
        sender: String?,
        visible: Bool,
        bodyPath: String,
        to: [ParsedAddress],
        cc: [ParsedAddress],
        bcc: [ParsedAddress],
        attachmentPaths: [String],
        send: Bool
    ) -> String {
        var props: [String] = []
        props.append("subject:\(AppleScript.quote(subject))")
        props.append("visible:\(visible ? "true" : "false")")
        if let s = sender {
            props.append("sender:\(AppleScript.quote(s))")
        }
        let propsLiteral = "{" + props.joined(separator: ", ") + "}"

        var lines: [String] = []
        lines.append("tell application \"Mail\"")
        lines.append("    set newMessage to make new outgoing message with properties \(propsLiteral)")
        lines.append("    tell newMessage")
        lines.append("        set content to (read (POSIX file \(AppleScript.quote(bodyPath))) as «class utf8»)")

        for r in to {
            lines.append("        make new to recipient at end of to recipients with properties \(recipientProps(r))")
        }
        for r in cc {
            lines.append("        make new cc recipient at end of cc recipients with properties \(recipientProps(r))")
        }
        for r in bcc {
            lines.append("        make new bcc recipient at end of bcc recipients with properties \(recipientProps(r))")
        }

        if !attachmentPaths.isEmpty {
            lines.append("        tell content")
            for path in attachmentPaths {
                lines.append("            make new attachment with properties {file name:(POSIX file \(AppleScript.quote(path)))} at after last paragraph")
            }
            lines.append("        end tell")
        }

        if send {
            lines.append("        send")
        }
        lines.append("    end tell")
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    private static func recipientProps(_ r: ParsedAddress) -> String {
        var parts: [String] = ["address:\(AppleScript.quote(r.address))"]
        if let n = r.displayName, !n.isEmpty {
            parts.append("name:\(AppleScript.quote(n))")
        }
        return "{" + parts.joined(separator: ", ") + "}"
    }
}
