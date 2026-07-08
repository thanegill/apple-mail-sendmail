import Foundation

public typealias ScriptRunner = (String) throws -> Void

public enum MailDriver {
    /// Hand the parsed message to Mail.app.
    ///
    /// - For messages with an HTML body, write a temp `.eml`, open it via
    ///   Launch Services (`open -a Mail file.eml`) so Mail spawns a viewer
    ///   window in WKWebView, then trigger "Send Again" (Cmd-Shift-D) via
    ///   System Events. That converts the viewer into a fresh editable
    ///   compose with full WKWebView fidelity -- the only path that preserves
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
    /// 1. Probes Accessibility (reads a UI element of another process, which
    ///    is Accessibility-gated and fails with -1719 when the controlling
    ///    process lacks the grant). Re-throws with a clear remediation
    ///    message so the binary surfaces a useful error.
    /// 2. Launches Mail and snapshots its existing window ids, so any
    ///    auto-restored windows are counted as "before".
    /// 3. `open -a Mail <eml>` via `do shell script` so Launch Services opens
    ///    the .eml as a Mail viewer window.
    /// 4. Polls for the viewer as the one window id that wasn't present
    ///    before the open -- matching by id, never by title, so it works for
    ///    messages with no Subject, duplicate subjects, or titles Mail
    ///    rewrites.
    /// 5. Snapshots ids again, then keystrokes Cmd-Shift-D (Send Again) to
    ///    the frontmost (freshly opened) viewer. Mail converts it into a new
    ///    editable compose window.
    /// 6. Polls for the compose as the one new window id since the keystroke.
    /// 7. If `send`, clicks `Message > Send` via System Events.
    /// 8. Closes the leftover viewer by its exact id (closing by title could
    ///    hit the compose window, which carries the same subject).
    static func buildEditDraftScript(
        emlPath: String,
        send: Bool
    ) -> String {
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
        // 2. Launch Mail and let auto-restored windows settle, then snapshot
        //    their ids. Anything present now is "before"; the eml viewer will
        //    be the only new id after the open. `launch` is a no-op if Mail
        //    is already running.
        lines.append("tell application \"Mail\" to launch")
        lines.append("delay 0.5")
        lines.append("tell application \"Mail\" to set beforeOpenIDs to id of every window")
        lines.append("")
        // 3. Open the .eml. Use POSIX file → quoted form to dodge shell injection.
        lines.append("do shell script \"open -a Mail \" & quoted form of \(pathLit)")
        lines.append("")
        // SINGLE-NEW-WINDOW ASSUMPTION: each poll below (viewer after `open`,
        // compose after Send Again) selects the FIRST window id that was not
        // present in the pre-step snapshot, and assumes exactly one new window
        // appears per step. If a session-restored window, a background sync
        // window, or a window the user opens by hand shows up during the run,
        // the diff can mis-select it instead of the one we spawned. This is
        // the known tradeoff of id-diffing: it is subject-title-independent
        // (works for empty/duplicate/rewritten subjects) at the cost of
        // assuming a quiet window set for the ~seconds the run takes. See
        // ATTEMPTS.md for why title-matching was abandoned.

        // 4. Poll for the viewer: the first window id not present before open.
        appendNewWindowPoll(
            &lines,
            resultVar: "viewerID",
            beforeVar: "beforeOpenIDs",
            timeoutMessage: "Mail did not open a viewer for the eml within 5s"
        )
        lines.append("")
        // 5. Snapshot ids again (now including the viewer) so we can detect
        //    the compose window Send Again creates. Then bring Mail to front
        //    and keystroke Cmd-Shift-D -- the viewer we just opened is the
        //    frontmost window, so the keystroke targets it.
        lines.append("tell application \"Mail\" to set beforeComposeIDs to id of every window")
        appendFrontmostAction(&lines, "keystroke \"d\" using {shift down, command down}")
        lines.append("")
        // 6. Poll for the compose: the first window id not present before the
        //    keystroke.
        appendNewWindowPoll(
            &lines,
            resultVar: "composeID",
            beforeVar: "beforeComposeIDs",
            timeoutMessage: "Compose window did not appear after Send Again within 5s"
        )
        lines.append("")
        if send {
            // 7. Click Message > Send via System Events.
            appendFrontmostAction(&lines, "click menu item \"Send\" of menu \"Message\" of menu bar 1")
            lines.append("")
            // 7b. Verify the send actually happened. On a successful send Mail
            //     closes the compose window, so its id disappears from
            //     `id of every window`. Poll for that id to be GONE; if it is
            //     still present after the deadline the send did not complete
            //     -- `error` so NSAppleScript throws and the binary exits
            //     non-zero instead of falsely reporting success.
            appendWindowGonePoll(
                &lines,
                targetVar: "composeID",
                timeoutMessage: "Send did not complete: the compose window is still open after 5s"
            )
            lines.append("")
        }
        // 8. Close the leftover viewer by its exact id. Closing by title could
        //    hit the compose window, which shares the subject.
        lines.append("tell application \"Mail\"")
        lines.append("    try")
        lines.append("        close (first window whose id is viewerID) saving no")
        lines.append("    end try")
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    // MARK: - Edit-draft script builders (shared)

    /// Append a poll loop that waits for a brand-new Mail window id -- the
    /// first id in `id of every window` that is NOT in the snapshot named by
    /// `beforeVar`. Stores it in `resultVar`, or `error`s with
    /// `timeoutMessage` if none appears within the deadline. See the
    /// single-new-window assumption note at the call site.
    private static func appendNewWindowPoll(
        _ lines: inout [String],
        resultVar: String,
        beforeVar: String,
        timeoutMessage: String
    ) {
        lines.append("set \(resultVar) to missing value")
        lines.append("set deadline to (current date) + 5")
        lines.append("repeat while (current date) < deadline and \(resultVar) is missing value")
        lines.append("    tell application \"Mail\"")
        lines.append("        repeat with wid in (id of every window)")
        lines.append("            if \(beforeVar) does not contain (contents of wid) then")
        lines.append("                set \(resultVar) to (contents of wid)")
        lines.append("                exit repeat")
        lines.append("            end if")
        lines.append("        end repeat")
        lines.append("    end tell")
        lines.append("    if \(resultVar) is missing value then delay 0.1")
        lines.append("end repeat")
        lines.append("if \(resultVar) is missing value then error \(AppleScript.quote(timeoutMessage))")
    }

    /// Append a poll loop that waits for the window id stored in `targetVar`
    /// to DISAPPEAR from `id of every window` (e.g. after a send closes the
    /// compose). `error`s with `timeoutMessage` if it is still present at the
    /// deadline, so a failed send surfaces as a non-zero exit.
    private static func appendWindowGonePoll(
        _ lines: inout [String],
        targetVar: String,
        timeoutMessage: String
    ) {
        lines.append("set \(targetVar)Gone to false")
        lines.append("set deadline to (current date) + 5")
        lines.append("repeat while (current date) < deadline and \(targetVar)Gone is false")
        lines.append("    tell application \"Mail\" to set currentIDs to id of every window")
        lines.append("    if currentIDs does not contain \(targetVar) then")
        lines.append("        set \(targetVar)Gone to true")
        lines.append("    else")
        lines.append("        delay 0.1")
        lines.append("    end if")
        lines.append("end repeat")
        lines.append("if \(targetVar)Gone is false then error \(AppleScript.quote(timeoutMessage))")
    }

    /// Append the focus preamble (activate Mail, settle, set the process
    /// frontmost) and then run `action` inside `tell process "Mail"` via
    /// System Events. Used for both the Send Again keystroke and the Send
    /// menu click, which both require Mail to be the frontmost process.
    private static func appendFrontmostAction(_ lines: inout [String], _ action: String) {
        lines.append("tell application \"Mail\" to activate")
        lines.append("delay 0.2")
        lines.append("tell application \"System Events\"")
        lines.append("    tell process \"Mail\"")
        lines.append("        set frontmost to true")
        lines.append("        \(action)")
        lines.append("    end tell")
        lines.append("end tell")
    }

    // MARK: - Classic script (plain-text path)

    private static func composeSender(name: String?, address: String?) -> String? {
        guard let addr = address else { return nil }
        return formatMailbox(name: name, address: addr)
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
