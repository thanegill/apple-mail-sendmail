import Foundation
#if canImport(AppKit)
import AppKit
#endif

public typealias ScriptRunner = (String) throws -> Void

public enum MailDriver {
    /// Hand the parsed message to Mail.app. When the message has HTML content,
    /// build a rich-text body via the AppleScript dictionary's rich text suite
    /// (paragraph-by-paragraph with per-paragraph font/size/color). When there
    /// is no HTML, fall through to the classic plain-text path. Both paths use
    /// the dictionary throughout — attachments and `send` work in the rich
    /// case the same as the classic case, and no UI scripting or Accessibility
    /// permission is required.
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

        if shouldUseRichBuild(msg) {
            if let paragraphs = extractParagraphs(fromHTML: msg.htmlBody ?? ""), !paragraphs.isEmpty {
                let richScript = buildRichBuildScript(
                    paragraphs: paragraphs,
                    subject: msg.subject,
                    sender: sender,
                    visible: !options.send,
                    to: msg.to,
                    cc: msg.cc,
                    bcc: msg.bcc,
                    attachmentPaths: attachmentURLs.map { $0.path },
                    send: options.send
                )
                do {
                    try run(richScript)
                    return richScript
                } catch {
                    warn("rich-build script failed (\(error)); falling back to plain-text compose")
                    try run(classicScript)
                    return classicScript
                }
            }
        }

        try run(classicScript)
        return classicScript
    }

    /// True iff the message has a non-empty HTML body. No restrictions on
    /// attachments or `--send` — the dictionary rich-build path handles all
    /// of those natively.
    static func shouldUseRichBuild(_ msg: ParsedMessage) -> Bool {
        guard let html = msg.htmlBody else { return false }
        return !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Paragraph extraction

    struct ParagraphSpec: Equatable {
        var text: String           // includes paragraph terminator(s)
        var fontName: String?
        var fontSize: CGFloat?
        var color: ASColor?
    }

    struct ASColor: Equatable {
        var r: UInt16
        var g: UInt16
        var b: UInt16
    }

    /// Render HTML through `NSAttributedString.initWithHTML:` and walk the
    /// resulting attributed string paragraph-by-paragraph. For each paragraph
    /// we read the first character's font and foreground color — sub-paragraph
    /// styling does not survive into Mail's rich text model.
    static func extractParagraphs(fromHTML html: String) -> [ParagraphSpec]? {
        #if canImport(AppKit)
        let withMeta = html.contains("<meta charset") ? html : ("<meta charset=\"utf-8\">\n" + html)
        guard let data = withMeta.data(using: .utf8) else { return nil }
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let attr = try? NSAttributedString(data: data, options: opts, documentAttributes: nil) else {
            return nil
        }

        var specs: [ParagraphSpec] = []
        let ns = attr.string as NSString
        let fullRange = NSRange(location: 0, length: attr.length)
        ns.enumerateSubstrings(in: fullRange, options: .byParagraphs) { _, _, enclosingRange, _ in
            guard enclosingRange.location < attr.length else { return }
            let text = ns.substring(with: enclosingRange)
            let attrs = attr.attributes(at: enclosingRange.location, effectiveRange: nil)
            let font = attrs[.font] as? NSFont
            let color = (attrs[.foregroundColor] as? NSColor).flatMap(Self.convert)
            specs.append(ParagraphSpec(
                text: text,
                fontName: font?.fontName,
                fontSize: font.map { $0.pointSize },
                color: color
            ))
        }
        return specs
        #else
        return nil
        #endif
    }

    #if canImport(AppKit)
    private static func convert(_ color: NSColor) -> ASColor? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func clamp(_ v: CGFloat) -> UInt16 { UInt16(max(0, min(1, v)) * 65535) }
        return ASColor(r: clamp(rgb.redComponent), g: clamp(rgb.greenComponent), b: clamp(rgb.blueComponent))
    }
    #endif

    // MARK: - Script builders

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

    /// Emit AppleScript that builds the compose body paragraph-by-paragraph
    /// using the rich text suite. Each paragraph carries its first-character
    /// font/size/color from the HTML render. Attachments go inline at the end.
    /// `send msg` is emitted if `options.send` is true; the dictionary handle
    /// survives all the paragraph operations.
    private static func buildRichBuildScript(
        paragraphs: [ParagraphSpec],
        subject: String,
        sender: String?,
        visible: Bool,
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
        lines.append("    activate")
        lines.append("    set newMessage to make new outgoing message with properties \(propsLiteral)")
        lines.append("    tell newMessage")
        lines.append("        set content to \"\"")

        for r in to {
            lines.append("        make new to recipient at end of to recipients with properties \(recipientProps(r))")
        }
        for r in cc {
            lines.append("        make new cc recipient at end of cc recipients with properties \(recipientProps(r))")
        }
        for r in bcc {
            lines.append("        make new bcc recipient at end of bcc recipients with properties \(recipientProps(r))")
        }

        lines.append("        tell content")
        for p in paragraphs {
            // Skip pure-empty paragraphs (artifacts of trailing \n at end of HTML)
            if p.text.isEmpty { continue }
            var pProps: [String] = []
            if let fn = p.fontName { pProps.append("font:\(AppleScript.quote(fn))") }
            if let fs = p.fontSize {
                pProps.append("size:\(formatSize(fs))")
            }
            if let c = p.color {
                pProps.append("color:{\(c.r), \(c.g), \(c.b)}")
            }
            let dataExpr = AppleScript.quote(p.text)
            if pProps.isEmpty {
                lines.append("            make new paragraph at end with data \(dataExpr)")
            } else {
                lines.append("            make new paragraph at end with data \(dataExpr) with properties {\(pProps.joined(separator: ", "))}")
            }
        }
        for path in attachmentPaths {
            lines.append("            make new attachment with properties {file name:(POSIX file \(AppleScript.quote(path)))} at after last paragraph")
        }
        lines.append("        end tell")

        if send {
            lines.append("        send")
        }
        lines.append("    end tell")
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    private static func formatSize(_ size: CGFloat) -> String {
        // Avoid 13.0 vs 13 round-trip surprises; emit a clean number.
        if size.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(size))
        }
        return String(format: "%.2f", Double(size))
    }

    private static func recipientProps(_ r: ParsedAddress) -> String {
        var parts: [String] = ["address:\(AppleScript.quote(r.address))"]
        if let n = r.displayName, !n.isEmpty {
            parts.append("name:\(AppleScript.quote(n))")
        }
        return "{" + parts.joined(separator: ", ") + "}"
    }
}
