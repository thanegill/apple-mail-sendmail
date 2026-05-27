import Foundation

public typealias ScriptRunner = (String) throws -> Void

public enum MailDriver {
    /// Hand the parsed message to Mail.app.
    ///
    /// - For messages with an HTML body, write a temp `.eml`, open it via
    ///   Launch Services (`open -a Mail file.eml`) so Mail spawns a viewer
    ///   window in WKWebView, then trigger "Send Again" (Cmd-Shift-D) via
    ///   System Events. That converts the viewer into a fresh editable
    ///   compose with full WKWebView fidelity — the only path that preserves
    ///   tables, CSS padding, monospace backgrounds, etc. Requires
    ///   Accessibility permission for the calling process.
    /// - For plain-text-only messages, use the classic AppleScript path
    ///   (`make new outgoing message` + `set content of msg to (read POSIX
    ///   file ... as «class utf8»)`). No Accessibility required.
    @discardableResult
    public static func deliver(
        _ msg: ParsedMessage,
        emlBytes: Data,
        options: Options,
        tmp: TempDir,
        runner: ScriptRunner? = nil
    ) throws -> String {
        let run = runner ?? { try AppleScript.run($0) }
        let sender = composeSender(name: options.fromName, address: options.fromAddress)

        if shouldUseEditDraft(msg) {
            let emlURL = try tmp.write(emlBytes, name: "compose-\(UUID().uuidString).eml")
            let script = buildEditDraftScript(
                emlPath: emlURL.path,
                subject: msg.subject,
                send: options.send
            )
            try run(script)
            return script
        }

        let bodyURL = try tmp.write(Data(msg.body.utf8), name: "body.txt")
        var attachmentURLs: [URL] = []
        for (idx, att) in msg.attachments.enumerated() {
            let prefix = String(format: "att-%02d-", idx + 1)
            let safe = sanitizeFilename(att.filename, fallback: "attachment-\(idx + 1).bin")
            let url = try tmp.write(att.data, name: prefix + safe)
            attachmentURLs.append(url)
        }
        let classic = buildClassicScript(
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
        try run(classic)
        return classic
    }

    /// True when the message has a non-empty HTML body. Drives the choice
    /// between the edit-draft path (Mail's WKWebView render) and the classic
    /// plain-text path.
    static func shouldUseEditDraft(_ msg: ParsedMessage) -> Bool {
        guard let html = msg.htmlBody else { return false }
        return !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Edit-draft script (HTML path)

    /// Emit AppleScript that:
    /// 1. Probes Accessibility (`tell System Events to get name of first
    ///    process` — fails with -1719 when the controlling process lacks
    ///    Accessibility permission). Re-throws with a clear remediation
    ///    message so the binary surfaces a useful error.
    /// 2. `open -a Mail <eml>` via `do shell script` so Launch Services opens
    ///    the .eml as a Mail viewer window.
    /// 3. Polls Mail for a window matching the subject (the rfc822 Subject
    ///    becomes the viewer window's title).
    /// 4. Brings that viewer to front and sends Cmd-Shift-D via System
    ///    Events. Mail's "Send Again" command converts the viewer into a
    ///    new editable compose.
    /// 5. If `send`, waits for the compose to appear (a second window with
    ///    the same name) and clicks `Message > Send` via System Events.
    /// 6. Closes the leftover viewer (best effort).
    static func buildEditDraftScript(
        emlPath: String,
        subject: String,
        send: Bool
    ) -> String {
        let subj = AppleScript.quote(subject)
        let pathLit = AppleScript.quote(emlPath)
        var lines: [String] = []
        lines.append("use scripting additions")
        lines.append("")
        // 1. Accessibility probe. Reading UI elements of another process is
        //    Accessibility-gated and returns -1719 when not granted, before
        //    we touch Mail at all. (Just enumerating processes via
        //    `get name of first process` doesn't require Accessibility, so
        //    we go deeper.)
        lines.append("try")
        lines.append("    tell application \"System Events\" to get name of menu bar 1 of process \"Finder\"")
        lines.append("on error errMsg number errNum")
        lines.append("    if errNum is -1719 or errNum is 1002 then")
        lines.append("        error \"Accessibility permission required. Grant apple-mail-sendmail Accessibility in System Settings > Privacy & Security > Accessibility.\" number errNum")
        lines.append("    else")
        lines.append("        error errMsg number errNum")
        lines.append("    end if")
        lines.append("end try")
        lines.append("")
        // 2. Open the .eml. Use POSIX file → quoted form to dodge shell injection.
        lines.append("do shell script \"open -a Mail \" & quoted form of \(pathLit)")
        lines.append("")
        // 3. Poll for the viewer window (subject == window name).
        lines.append("set subjLine to \(subj)")
        lines.append("set viewerW to missing value")
        lines.append("set deadline to (current date) + 5")
        lines.append("repeat while (current date) < deadline and viewerW is missing value")
        lines.append("    tell application \"Mail\"")
        lines.append("        repeat with w in windows")
        lines.append("            if (name of w) is subjLine then")
        lines.append("                set viewerW to w")
        lines.append("                exit repeat")
        lines.append("            end if")
        lines.append("        end repeat")
        lines.append("    end tell")
        lines.append("    if viewerW is missing value then delay 0.1")
        lines.append("end repeat")
        lines.append("if viewerW is missing value then error \"Mail did not open a viewer for the eml within 5s\"")
        lines.append("")
        // 4. Bring viewer to front and keystroke Cmd-Shift-D (Send Again).
        lines.append("tell application \"Mail\" to activate")
        lines.append("delay 0.2")
        lines.append("tell application \"System Events\"")
        lines.append("    tell process \"Mail\"")
        lines.append("        set frontmost to true")
        lines.append("        keystroke \"d\" using {shift down, command down}")
        lines.append("    end tell")
        lines.append("end tell")
        lines.append("")
        // 5. Poll for the compose window (two windows with matching name).
        lines.append("set composeAppeared to false")
        lines.append("set deadline to (current date) + 5")
        lines.append("repeat while (current date) < deadline and composeAppeared is false")
        lines.append("    tell application \"Mail\"")
        lines.append("        set matchCount to 0")
        lines.append("        repeat with w in windows")
        lines.append("            if (name of w) is subjLine then set matchCount to matchCount + 1")
        lines.append("        end repeat")
        lines.append("    end tell")
        lines.append("    if matchCount ≥ 2 then set composeAppeared to true")
        lines.append("    if not composeAppeared then delay 0.1")
        lines.append("end repeat")
        lines.append("if not composeAppeared then error \"Compose window did not appear after Send Again within 5s\"")
        lines.append("")
        if send {
            // 6. Click Message > Send via System Events.
            lines.append("tell application \"Mail\" to activate")
            lines.append("delay 0.2")
            lines.append("tell application \"System Events\"")
            lines.append("    tell process \"Mail\"")
            lines.append("        set frontmost to true")
            lines.append("        click menu item \"Send\" of menu \"Message\" of menu bar 1")
            lines.append("    end tell")
            lines.append("end tell")
            lines.append("")
        }
        // 7. Close the leftover viewer. Iterate windows by name and close the
        //    first match — by z-order that is the older viewer, since the new
        //    compose is the frontmost matching window.
        lines.append("tell application \"Mail\"")
        lines.append("    try")
        lines.append("        repeat with w in windows")
        lines.append("            if (name of w) is subjLine then")
        lines.append("                close w saving no")
        lines.append("                exit repeat")
        lines.append("            end if")
        lines.append("        end repeat")
        lines.append("    end try")
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    // MARK: - Classic script (plain-text path)

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

    private static func recipientProps(_ r: ParsedAddress) -> String {
        var parts: [String] = ["address:\(AppleScript.quote(r.address))"]
        if let n = r.displayName, !n.isEmpty {
            parts.append("name:\(AppleScript.quote(n))")
        }
        return "{" + parts.joined(separator: ", ") + "}"
    }
}
