import Foundation

public typealias ScriptRunner = (String) throws -> Void

public enum MailDriver {
    /// Hand the parsed message to Mail.app. Writes the body and attachments to
    /// `tmp`, generates one or two AppleScripts, and passes them to `runner`.
    /// Defaults to executing scripts via NSAppleScript; tests inject a recording
    /// runner. Returns the script that was last successfully invoked (the rich
    /// HTML script when the rich path succeeds, otherwise the classic script —
    /// including the case where the rich path failed and we fell back).
    @discardableResult
    public static func deliver(
        _ msg: ParsedMessage,
        options: Options,
        tmp: TempDir,
        runner: ScriptRunner? = nil
    ) throws -> String {
        let bodyURL = try tmp.write(Data(msg.body.utf8), name: "body.txt")

        var attachmentURLs: [URL] = []
        for (idx, att) in msg.attachments.enumerated() {
            let prefix = String(format: "att-%02d-", idx + 1)
            let safe = sanitizeFilename(att.filename, fallback: "attachment-\(idx + 1).bin")
            let url = try tmp.write(att.data, name: prefix + safe)
            attachmentURLs.append(url)
        }

        let sender = composeSender(name: options.fromName, address: options.fromAddress)
        let run = runner ?? { try AppleScript.run($0) }

        let classicScript = buildClassicScript(
            subject: msg.subject,
            sender: sender,
            visible: !options.send,
            bodyPath: bodyURL.path,
            to: msg.to,
            cc: msg.cc,
            bcc: msg.bcc,
            attachmentPaths: attachmentURLs.map { $0.path },
            send: options.send
        )

        // Warn when HTML was present but a condition forces the classic path,
        // so the user understands why styling was stripped.
        let hasRichHTML = hasNonEmptyHTML(msg)
        if hasRichHTML && !msg.attachments.isEmpty {
            warn("HTML present but attachments require classic path; styling will be stripped")
        } else if hasRichHTML && options.send {
            warn("HTML present but --send requires classic path; styling will be stripped")
        }

        if shouldUseRichHTML(msg, options: options) {
            if !msg.bcc.isEmpty {
                warn("Bcc will be visible in the rich-HTML compose window (NSSharingService has no Bcc field)")
            }
            // NSAttributedString.initWithHTML guesses the encoding from the
            // document. Sender HTML often lacks a <meta charset>, so non-ASCII
            // bytes (em dashes, box-drawing characters) come out as Latin-1
            // mojibake. Prepend a UTF-8 hint so the parser reads our temp file
            // correctly.
            let htmlWithCharset = "<meta charset=\"utf-8\">\n" + (msg.htmlBody ?? "")
            let htmlURL = try tmp.write(Data(htmlWithCharset.utf8), name: "body.html")
            let richScript = buildRichHTMLScript(
                subject: msg.subject,
                htmlPath: htmlURL.path,
                to: msg.to,
                cc: msg.cc,
                bcc: msg.bcc
            )
            do {
                try run(richScript)
                return richScript
            } catch {
                warn("rich HTML render failed (\(error)); falling back to plain-text compose")
                try run(classicScript)
                return classicScript
            }
        }

        try run(classicScript)
        return classicScript
    }

    /// True iff the message has a non-empty HTML body, no attachments, and is
    /// not being sent automatically. NSSharingService strips attachments and
    /// will not auto-send, so attach/send cases must use the classic path.
    static func shouldUseRichHTML(_ msg: ParsedMessage, options: Options) -> Bool {
        guard hasNonEmptyHTML(msg) else { return false }
        if !msg.attachments.isEmpty { return false }
        if options.send { return false }
        return true
    }

    private static func hasNonEmptyHTML(_ msg: ParsedMessage) -> Bool {
        guard let html = msg.htmlBody else { return false }
        return !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func composeSender(name: String?, address: String?) -> String? {
        if let addr = address, let n = name, !n.isEmpty {
            return "\(n) <\(addr)>"
        }
        return address
    }

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

    /// Emit an AppleScript-ObjC source that builds an NSAttributedString from
    /// the HTML file and hands it to NSSharingService's compose-email service.
    ///
    /// Two things matter for this to actually open a compose window from a CLI
    /// context (verified empirically against macOS 15):
    ///   * Mail must be activated first. NSSharingService is a no-op when its
    ///     target host isn't already running and frontmost.
    ///   * After `performWithItems:` is called, the script must keep its
    ///     runloop running for a moment so the async dispatch to Mail can
    ///     complete. `performSelectorOnMainThread:waitUntilDone:true` returns
    ///     `done` but the window never appears; a real `runUntilDate:` does.
    private static func buildRichHTMLScript(
        subject: String,
        htmlPath: String,
        to: [ParsedAddress],
        cc: [ParsedAddress],
        bcc: [ParsedAddress]
    ) -> String {
        // NSSharingService has no separate Cc/Bcc fields; collate everyone into
        // the single recipients list. Bcc visibility is warned about in deliver().
        let allRecipients = to + cc + bcc
        let recipientList = allRecipients
            .map { AppleScript.quote($0.address) }
            .joined(separator: ", ")

        var lines: [String] = []
        lines.append("use framework \"Foundation\"")
        lines.append("use framework \"AppKit\"")
        lines.append("use scripting additions")
        lines.append("")
        lines.append("set htmlPath to \(AppleScript.quote(htmlPath))")
        lines.append("set htmlString to (current application's NSString's stringWithContentsOfFile:htmlPath encoding:(current application's NSUTF8StringEncoding) |error|:(missing value))")
        lines.append("if htmlString is missing value then error \"failed to read HTML body\" number 65")
        lines.append("set htmlData to htmlString's dataUsingEncoding:(current application's NSUTF8StringEncoding)")
        lines.append("set attrStr to (current application's NSAttributedString's alloc()'s initWithHTML:htmlData documentAttributes:(missing value))")
        lines.append("if attrStr is missing value then error \"failed to construct NSAttributedString from HTML\" number 65")
        lines.append("")
        lines.append("-- Mail must be frontmost for NSSharingService to actually present the compose window.")
        lines.append("tell application \"Mail\" to activate")
        lines.append("")
        lines.append("set svc to current application's NSSharingService's sharingServiceNamed:(current application's NSSharingServiceNameComposeEmail)")
        lines.append("if svc is missing value then error \"compose-email sharing service unavailable\" number 71")
        lines.append("set svc's recipients to {\(recipientList)}")
        lines.append("set svc's subject to \(AppleScript.quote(subject))")
        lines.append("svc's performWithItems:{attrStr}")
        lines.append("")
        lines.append("-- Spin the runloop so NSSharingService's async dispatch reaches Mail before we exit.")
        lines.append("current application's NSRunLoop's currentRunLoop()'s runUntilDate:(current application's NSDate's dateWithTimeIntervalSinceNow:2.0)")
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
