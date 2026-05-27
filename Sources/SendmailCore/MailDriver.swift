import Foundation
#if canImport(AppKit)
import AppKit
#endif

public typealias ScriptRunner = (String) throws -> Void

public enum MailDriver {
    /// Hand the parsed message to Mail.app. When the message has HTML content,
    /// convert it to RTF (via `NSAttributedString.initWithHTML:` + font
    /// substitution to Mail's preferences), write to a temp file, and have
    /// AppleScript do `set content of msg to (read POSIX file ... as «class
    /// RTF »)`. This preserves sub-paragraph styling (inline bold/italic/
    /// colored spans) that the per-paragraph approach loses. Attachments are
    /// added inline via dictionary `make new attachment`; `send msg` via
    /// dictionary covers `--send` mode. The RTF read requires Mail's app-level
    /// `default message format` to be `rich format` for the duration of the
    /// compose; the emitter saves/restores it via try/error.
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
            if let rtfData = renderHTMLToRTF(html: msg.htmlBody ?? "", fontPrefs: .current()) {
                let rtfURL = try tmp.write(rtfData, name: "body.rtf")
                let richScript = buildRichRTFScript(
                    rtfPath: rtfURL.path,
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
                    warn("rich-RTF script failed (\(error)); falling back to plain-text compose")
                    try run(classicScript)
                    return classicScript
                }
            }
        }

        try run(classicScript)
        return classicScript
    }

    /// True iff the message has a non-empty HTML body. No restrictions on
    /// attachments or `--send` — the rich-RTF path handles all of them via
    /// the dictionary.
    static func shouldUseRichBuild(_ msg: ParsedMessage) -> Bool {
        guard let html = msg.htmlBody else { return false }
        return !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Font preferences

    /// Default fonts mirroring Mail's "Fonts & Colors" preferences pane.
    /// Read at runtime from the `com.apple.mail` defaults; tests can supply
    /// their own values for deterministic output.
    public struct MailFontPrefs: Equatable {
        public var messageFontName: String
        public var messageFontSize: CGFloat
        public var fixedPitchFontName: String
        public var fixedPitchFontSize: CGFloat

        public init(
            messageFontName: String,
            messageFontSize: CGFloat,
            fixedPitchFontName: String,
            fixedPitchFontSize: CGFloat
        ) {
            self.messageFontName = messageFontName
            self.messageFontSize = messageFontSize
            self.fixedPitchFontName = fixedPitchFontName
            self.fixedPitchFontSize = fixedPitchFontSize
        }

        /// Built-in defaults matching Apple's stock Mail.app settings.
        public static let appleDefaults = MailFontPrefs(
            messageFontName: "Helvetica",
            messageFontSize: 12,
            fixedPitchFontName: "Menlo-Regular",
            fixedPitchFontSize: 11
        )

        /// Read from `com.apple.mail` UserDefaults. Falls back to
        /// `appleDefaults` for any missing key.
        public static func current() -> MailFontPrefs {
            let d = UserDefaults(suiteName: "com.apple.mail")
            func size(_ key: String, _ fallback: CGFloat) -> CGFloat {
                if let n = d?.object(forKey: key) as? NSNumber {
                    return CGFloat(truncating: n)
                }
                return fallback
            }
            return MailFontPrefs(
                messageFontName: d?.string(forKey: "NSFont") ?? appleDefaults.messageFontName,
                messageFontSize: size("NSFontSize", appleDefaults.messageFontSize),
                fixedPitchFontName: d?.string(forKey: "NSFixedPitchFont") ?? appleDefaults.fixedPitchFontName,
                fixedPitchFontSize: size("NSFixedPitchFontSize", appleDefaults.fixedPitchFontSize)
            )
        }
    }

    // MARK: - HTML → RTF

    /// Convert an HTML string to RTF data, substituting per-run fonts so
    /// proportional content uses Mail's Message font and monospace content
    /// uses Mail's Fixed-width font. The result is binary RTF suitable for
    /// `set content of msg to (read POSIX file ... as «class RTF »)`.
    public static func renderHTMLToRTF(html: String, fontPrefs: MailFontPrefs = .current()) -> Data? {
        #if canImport(AppKit)
        let withMeta = html.contains("<meta charset") ? html : ("<meta charset=\"utf-8\">\n" + html)
        guard let data = withMeta.data(using: .utf8) else { return nil }
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let mutableAttr = try? NSMutableAttributedString(data: data, options: opts, documentAttributes: nil) else {
            return nil
        }

        let fullRange = NSRange(location: 0, length: mutableAttr.length)

        // Collect (range, original-font) pairs first so we don't mutate during
        // enumeration. Then substitute fonts per-run.
        var subs: [(NSRange, NSFont)] = []
        mutableAttr.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            if let font = value as? NSFont {
                subs.append((range, font))
            }
        }
        for (range, originalFont) in subs {
            let isMono = originalFont.isFixedPitch
            let name = isMono ? fontPrefs.fixedPitchFontName : fontPrefs.messageFontName
            let size = isMono ? fontPrefs.fixedPitchFontSize : fontPrefs.messageFontSize
            if let newFont = NSFont(name: name, size: size) {
                mutableAttr.addAttribute(.font, value: newFont, range: range)
            }
        }

        return try? mutableAttr.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        #else
        return nil
        #endif
    }

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

    /// Emit AppleScript that reads the RTF body from disk and sets it as the
    /// new outgoing message's content. Mail's app-level `default message
    /// format` must be `rich format` for the RTF coercion to survive; we
    /// snapshot, flip (only if needed), and restore in try/error.
    ///
    /// `read` must be outside the `tell application "Mail"` block so it
    /// resolves to Standard Additions, not to a Mail term.
    private static func buildRichRTFScript(
        rtfPath: String,
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
        // No `use AppleScript version "2.4"` — that preamble makes the
        // parser strict enough to reject the «class RTF » raw four-char-code
        // coercion. `use scripting additions` alone is fine and keeps `read`
        // resolving correctly.
        lines.append("use scripting additions")
        lines.append("")
        lines.append("set rtfData to (read POSIX file \(AppleScript.quote(rtfPath)) as «class RTF »)")
        lines.append("")
        lines.append("tell application \"Mail\"")
        lines.append("    activate")
        lines.append("    set originalFormat to default message format")
        lines.append("    if originalFormat is not rich format then")
        lines.append("        set default message format to rich format")
        lines.append("    end if")
        lines.append("    try")
        lines.append("        set newMessage to make new outgoing message with properties \(propsLiteral)")
        lines.append("        tell newMessage")
        for r in to {
            lines.append("            make new to recipient at end of to recipients with properties \(recipientProps(r))")
        }
        for r in cc {
            lines.append("            make new cc recipient at end of cc recipients with properties \(recipientProps(r))")
        }
        for r in bcc {
            lines.append("            make new bcc recipient at end of bcc recipients with properties \(recipientProps(r))")
        }
        lines.append("        end tell")
        lines.append("        set content of newMessage to rtfData")
        if !attachmentPaths.isEmpty {
            lines.append("        tell newMessage")
            lines.append("            tell content")
            for path in attachmentPaths {
                lines.append("                make new attachment with properties {file name:(POSIX file \(AppleScript.quote(path)))} at after last paragraph")
            }
            lines.append("            end tell")
            lines.append("        end tell")
        }
        if send {
            lines.append("        tell newMessage to send")
        }
        lines.append("    on error errMsg")
        lines.append("        if originalFormat is not rich format then")
        lines.append("            set default message format to originalFormat")
        lines.append("        end if")
        lines.append("        error errMsg")
        lines.append("    end try")
        lines.append("    if originalFormat is not rich format then")
        lines.append("        set default message format to originalFormat")
        lines.append("    end if")
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
