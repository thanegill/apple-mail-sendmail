import Foundation

public typealias ScriptRunner = (String) throws -> Void

/// Both deliveries by generated AppleScript, handed to a `ScriptRunner`
/// (`AppleScript.run` by default; tests and the dry run record or print the
/// script instead).
public struct AppleScriptMailAutomation: PlainDelivery, HTMLDelivery {
    /// Where the plain path stages the body file its script reads.
    let staging: TempDir
    let accessibility: AccessibilityPermission
    let runner: ScriptRunner

    public init(
        staging: TempDir,
        accessibility: AccessibilityPermission = .system(),
        runner: @escaping ScriptRunner = { try AppleScript.run($0) }
    ) {
        self.staging = staging
        self.accessibility = accessibility
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

    /// Checks Accessibility before Mail is touched: the script's System
    /// Events menu clicks need it.
    public func deliverHTML(emlURL: URL, send: Bool) throws {
        try accessibility.require()
        try runner(Self.buildEditDraftScript(emlPath: emlURL.path, send: send))
    }

    // MARK: - Edit-draft script (HTML path)

    /// Emit AppleScript that (after `deliverHTML` has checked Accessibility
    /// in Swift):
    /// 1. Launches Mail and snapshots its existing window ids, so any
    ///    auto-restored windows are counted as "before".
    /// 2. `open -a Mail <eml>` via `do shell script` so Launch Services opens
    ///    the .eml as a Mail viewer window.
    /// 3. Polls for the viewer as the one window id that wasn't present
    ///    before the open, ignoring sheet entries -- matching by id, never by
    ///    title, so it works for messages with no Subject, duplicate
    ///    subjects, or titles Mail rewrites.
    /// 4. Snapshots ids again, raises the viewer by id, and clicks
    ///    Message > Send Again (Cmd-Shift-D) via System Events only once the
    ///    viewer is verified front, main and key -- erroring out otherwise;
    ///    see `appendVerifiedFrontWindowAction`. Mail converts the viewer
    ///    into a new editable compose window.
    /// 5. Polls for the compose as the one new window id since the click.
    /// 6. If `send`, waits for `Message > Send` to be enabled, raises the
    ///    compose window and verifies it the same way, clicks Send via System
    ///    Events, and polls for the compose to close -- retrying a bounded
    ///    number of times; see `appendSendWithRetry`.
    /// 7. Closes the leftover viewer by its exact id (closing by title could
    ///    hit the compose window, which carries the same subject).
    ///
    /// Public so tests can compile it against arbitrary `emlPath` values.
    public static func buildEditDraftScript(
        emlPath: String,
        send: Bool
    ) -> String {
        let pathLit = AppleScript.quote(emlPath)
        var lines: [String] = []
        lines.append("use scripting additions")
        lines.append("")
        // 1. Launch Mail and let auto-restored windows settle, then snapshot
        //    their ids. Anything present now is "before"; the eml viewer will
        //    be the only new id after the open. `launch` is a no-op if Mail
        //    is already running.
        lines.append("tell application \"Mail\" to launch")
        lines.append("delay 0.5")
        lines.append("tell application \"Mail\" to set beforeOpenIDs to id of every window")
        lines.append("")
        // 2. Open the .eml. Use POSIX file → quoted form to dodge shell injection.
        lines.append("do shell script \"open -a Mail \" & quoted form of \(pathLit)")
        lines.append("")
        // SINGLE-NEW-WINDOW ASSUMPTION: each poll below (viewer after `open`,
        // compose after Send Again) takes the one window id that was not
        // present in the pre-step snapshot, ignoring sheet entries. Two new
        // ids seen at once fail closed. But a stray window (session restore,
        // background sync, one the user opens) that appears ALONE in place of
        // ours, or a moment before ours, is still mis-selected. This is the
        // known tradeoff of id-diffing: it is subject-title-independent
        // (works for empty/duplicate/rewritten subjects) at the cost of
        // assuming a quiet window set for the ~seconds the run takes. See
        // ATTEMPTS.md for why title-matching was abandoned.

        // 3. Poll for the viewer: the one new window id since the open.
        appendNewWindowPoll(
            &lines,
            resultVar: "viewerID",
            beforeVar: "beforeOpenIDs",
            windowName: "eml viewer",
            timeoutMessage: "Mail did not open a viewer for the eml within 5s"
        )
        lines.append("")
        // 4. Snapshot ids again (now including the viewer) so we can detect
        //    the compose window Send Again creates. Then raise the viewer,
        //    verify it is front, main and key, and only then click
        //    Message > Send Again.
        lines.append("tell application \"Mail\" to set beforeComposeIDs to id of every window")
        appendVerifiedFrontWindowAction(
            &lines,
            windowVar: "viewerID",
            windowName: "eml viewer",
            actionName: "the Send Again menu click",
            action: "click menu item \"Send Again\" of menu \"Message\" of menu bar 1"
        )
        lines.append("")
        // 5. Poll for the compose: the one new window id since the click.
        appendNewWindowPoll(
            &lines,
            resultVar: "composeID",
            beforeVar: "beforeComposeIDs",
            windowName: "compose",
            timeoutMessage: "Compose window did not appear after Send Again within 5s"
        )
        lines.append("")
        if send {
            appendSendWithRetry(&lines)
            lines.append("")
        }
        // 7. Close the leftover viewer by its exact id. Closing by title could
        //    hit the compose window, which shares the subject.
        lines.append("tell application \"Mail\"")
        lines.append("    try")
        lines.append("        close (first window whose id is viewerID) saving no")
        lines.append("    end try")
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    // MARK: - Edit-draft script builders (shared)

    /// The `name` Mail gives the extra entry a sheet (e.g. the Attach file
    /// sheet) adds to its `windows`, with an id of its own.
    private static let sheetWindowName = "Save Panel Accessory View"

    /// Append a poll loop that waits for a brand-new Mail window id -- an id
    /// in `id of every window` that is NOT in the snapshot named by
    /// `beforeVar` and is not a sheet entry (`sheetWindowName`). Stores it in
    /// `resultVar`. `error`s with `timeoutMessage` if none appears within the
    /// deadline, and fails closed if more than one appears at once rather
    /// than guessing which is ours. See the single-new-window note at the
    /// call site.
    private static func appendNewWindowPoll(
        _ lines: inout [String],
        resultVar: String,
        beforeVar: String,
        windowName: String,
        timeoutMessage: String
    ) {
        let candidatesVar = "\(resultVar)Candidates"
        lines.append("set \(resultVar) to missing value")
        lines.append("set deadline to (current date) + 5")
        lines.append("repeat while (current date) < deadline and \(resultVar) is missing value")
        lines.append("    set \(candidatesVar) to {}")
        // Materialize the id list into an AppleScript variable before
        // iterating. `repeat with wid in (id of every window)` keeps the
        // right-hand side as a live Mail reference, so dereferencing
        // `item i of id of every window` gets sent back to Mail and fails
        // with -1700 ("can't make ... into type specifier"). Assigning to a
        // plain variable first forces evaluation to a list value.
        lines.append("    tell application \"Mail\" to set winIDs to id of every window")
        lines.append("    repeat with wid in winIDs")
        lines.append("        if \(beforeVar) does not contain (contents of wid) then")
        lines.append("            set candidateID to (contents of wid)")
        // A window that closes between the id read and the name read is
        // skipped, not treated as a candidate.
        lines.append("            try")
        lines.append("                tell application \"Mail\" to set candidateName to name of (first window whose id is candidateID)")
        lines.append("                if candidateName is not \(AppleScript.quote(sheetWindowName)) then set end of \(candidatesVar) to candidateID")
        lines.append("            end try")
        lines.append("        end if")
        lines.append("    end repeat")
        let ambiguousMessage = "Mail opened more than one new window while waiting for the \(windowName); refusing to guess which is ours (found "
        lines.append("    if (count of \(candidatesVar)) > 1 then error \(AppleScript.quote(ambiguousMessage)) & (count of \(candidatesVar)) & \")\"")
        lines.append("    if (count of \(candidatesVar)) is 1 then")
        lines.append("        set \(resultVar) to item 1 of \(candidatesVar)")
        lines.append("    else")
        lines.append("        delay 0.1")
        lines.append("    end if")
        lines.append("end repeat")
        lines.append("if \(resultVar) is missing value then error \(AppleScript.quote(timeoutMessage))")
    }

    private static func indented(_ lines: [String], by indent: String) -> [String] {
        lines.map { $0.isEmpty ? $0 : indent + $0 }
    }

    /// Append a poll loop that waits up to `seconds` for the window id stored
    /// in `targetVar` to DISAPPEAR from `id of every window` (e.g. after a
    /// send closes the compose), leaving the result in `<targetVar>Gone`.
    private static func appendWindowGonePoll(
        _ lines: inout [String],
        targetVar: String,
        seconds: Int,
        indent: String
    ) {
        lines += indented([
            "set \(targetVar)Gone to false",
            "set deadline to (current date) + \(seconds)",
            "repeat while (current date) < deadline and \(targetVar)Gone is false",
            "    tell application \"Mail\" to set currentIDs to id of every window",
            "    if currentIDs does not contain \(targetVar) then",
            "        set \(targetVar)Gone to true",
            "    else",
            "        delay 0.1",
            "    end if",
            "end repeat",
        ], by: indent)
    }

    private static let sendMenuItem = "menu item \"Send\" of menu \"Message\" of menu bar 1"
    private static let maxSendClicks = 3

    /// Append the `--send` step: up to `maxSendClicks` attempts, each one
    /// waiting for Message > Send to be ready, running the full key-window
    /// guard on the compose, clicking Send, then polling ~3s for the compose
    /// to close. Live, a Send clicked right after Send Again on a message
    /// with an attachment was ignored while Mail loaded the attachment, so
    /// one click is not enough. If a sheet (e.g. a Mail warning) is open on
    /// the still-open compose, it fails closed at once rather than click
    /// through it. If the compose is still open after the last attempt it
    /// `error`s, so a failed send exits non-zero instead of reporting
    /// success.
    private static func appendSendWithRetry(_ lines: inout [String]) {
        let clicksVar = "composeSendClicks"
        lines.append("set composeIDGone to false")
        lines.append("set \(clicksVar) to 0")
        // Retrying is safe ONLY because Mail closes the compose window when
        // it accepts Send, so a compose id still present after the poll
        // means the click was not taken. If Mail ever kept the compose open
        // after a send, or the poll stopped tracking composeID, a retry
        // would send the message twice.
        lines.append("repeat while composeIDGone is false and \(clicksVar) < \(maxSendClicks)")
        appendSendMenuReadinessWait(&lines, indent: "    ")
        appendVerifiedFrontWindowAction(
            &lines,
            windowVar: "composeID",
            windowName: "compose",
            actionName: "the Send menu click",
            action: "click \(sendMenuItem)",
            indent: "    "
        )
        lines.append("    set \(clicksVar) to \(clicksVar) + 1")
        appendWindowGonePoll(&lines, targetVar: "composeID", seconds: 3, indent: "    ")
        // Fast fail on a sheet, checked only when the compose is Mail's
        // front window (so AXMainWindow is the compose). Otherwise the next
        // attempt's guard refuses to click while the main window has a sheet.
        lines += indented([
            "if composeIDGone is false then",
            "    set composeSheetCount to 0",
            "    try",
            "        tell application \"Mail\" to set frontWindowID to id of window 1",
            "        if frontWindowID is composeID then",
            "            tell application \"System Events\" to tell process \"Mail\" to set composeSheetCount to count of sheets of (value of attribute \"AXMainWindow\")",
            "        end if",
            "    end try",
            "    if composeSheetCount > 0 then error \"A sheet is open on the compose window after the Send menu click; not clicking Send through it, and the message was not sent\"",
            "end if",
        ], by: "    ")
        lines.append("end repeat")
        lines.append("if composeIDGone is false then error \"Send did not complete: the compose window is still open after \(maxSendClicks) Send menu clicks\"")
    }

    /// Append a bounded wait for Mail's Message > Send item to exist and be
    /// enabled. Right after Send Again, Mail is still loading an attachment
    /// into the new compose; a Send click then is ignored, or the item is
    /// not there yet (-1728). A failed read means "not ready yet".
    private static func appendSendMenuReadinessWait(_ lines: inout [String], indent: String) {
        lines += indented([
            "set sendMenuReady to false",
            "set sdeadline to (current date) + 10",
            "repeat until sendMenuReady or (current date) > sdeadline",
            "    try",
            "        tell application \"System Events\" to tell process \"Mail\" to set sendMenuReady to (enabled of \(sendMenuItem) is true)",
            "    end try",
            "    if not sendMenuReady then delay 0.2",
            "end repeat",
            "if not sendMenuReady then error \"Mail's Message > Send menu item did not become available within 10s; the compose was not sent\"",
        ], by: indent)
    }

    /// Raise the Mail window whose id is stored in `windowVar` and click
    /// `action` (a Mail menu item) via System Events only once that window
    /// is verified to be the one it will act on. Mail's menu commands act on
    /// its KEY window, so Send on the user's own draft would send it. A
    /// click on `process "Mail"` cannot reach another app, but with Mail not
    /// frontmost the click silently does nothing, so frontmost is still
    /// required.
    ///
    /// Each attempt runs inside one `tell process "Mail"` block and requires,
    /// in order: Mail is frontmost; Mail's `window 1` (stacking order) is the
    /// target id; the key window (AXFocusedWindow) is the main window, so no
    /// panel or sheet holds key; the main window (AXMainWindow) is an
    /// AXStandardWindow with no sheets; and its AXTitle equals Mail's `name`
    /// of the target -- a cross-check only, the target is still chosen by id.
    /// The action is the next statement after the last check. A failed or
    /// unreadable check re-raises and retries until the 3s deadline, then
    /// `error`s naming the last failed check; the action never runs
    /// unverified. If the target window disappears it `error`s naming it.
    ///
    /// Key == main is read as AXMain of the AXFocusedWindow element rather
    /// than by comparing two System Events references: the boolean read
    /// does not depend on how AppleScript compares UI element specifiers.
    /// A sheet holding key fails that check either way: AXMain reads as not
    /// true, or the read errors (as its AXTitle read does), which counts as
    /// a failed check.
    ///
    /// Still trusts that the id-diff picked the right window (#33), and the
    /// check-then-act gap can be narrowed but not closed.
    private static func appendVerifiedFrontWindowAction(
        _ output: inout [String],
        windowVar: String,
        windowName: String,
        actionName: String,
        action: String,
        indent: String = ""
    ) {
        var lines: [String] = []
        defer { output += indented(lines, by: indent) }
        let actedVar = "\(windowVar)Acted"
        let failedCheckVar = "\(windowVar)FailedCheck"
        let focus = "tell application \"System Events\" to set frontmost of process \"Mail\" to true"
        let closedMessage = "\(AppleScript.quote("The \(windowName) window (id ")) & \(windowVar) & \(AppleScript.quote(") closed before \(actionName): ")) & errMsg"
        func closedOnError(_ body: [String], indent: String) -> [String] {
            ["\(indent)try"]
                + body.map { "\(indent)    \($0)" }
                + [
                    "\(indent)on error errMsg number errNum",
                    "\(indent)    error \(closedMessage) number errNum",
                    "\(indent)end try",
                ]
        }
        func failCheck(_ reason: String) -> String {
            "set \(failedCheckVar) to \(AppleScript.quote(reason))"
        }
        let raise = "tell application \"Mail\" to set index of (first window whose id is \(windowVar)) to 1"
        lines.append("tell application \"Mail\" to activate")
        lines.append(focus)
        lines += closedOnError([raise], indent: "")
        lines.append("delay 0.3")
        lines.append("set \(actedVar) to false")
        lines.append(failCheck("no check ran"))
        lines.append("set fdeadline to (current date) + 3")
        lines.append("repeat until \(actedVar) or (current date) > fdeadline")
        lines.append("    tell application \"System Events\"")
        lines.append("        tell process \"Mail\"")
        lines += closedOnError([
            "tell application \"Mail\"",
            "    set frontWindowID to id of window 1",
            "    set targetName to name of (first window whose id is \(windowVar))",
            "end tell",
        ], indent: "            ")
        lines.append("            set \(failedCheckVar) to \"\"")
        lines.append("            try")
        lines.append("                if not frontmost then")
        lines.append("                    \(failCheck("Mail is not the frontmost app"))")
        lines.append("                else if frontWindowID is not \(windowVar) then")
        lines.append("                    \(failCheck("Mail's window 1 is not the \(windowName) window"))")
        lines.append("                else")
        lines.append("                    set keyWindow to value of attribute \"AXFocusedWindow\"")
        lines.append("                    set mainWindow to value of attribute \"AXMainWindow\"")
        lines.append("                    if value of attribute \"AXMain\" of keyWindow is not true then")
        lines.append("                        \(failCheck("the key window (AXFocusedWindow) is not the main window (AXMainWindow); a panel or sheet holds key"))")
        lines.append("                    else if value of attribute \"AXSubrole\" of mainWindow is not \"AXStandardWindow\" then")
        lines.append("                        \(failCheck("the main window (AXMainWindow) is not an AXStandardWindow"))")
        lines.append("                    else if (count of sheets of mainWindow) is not 0 then")
        lines.append("                        \(failCheck("the main window (AXMainWindow) has a sheet open"))")
        lines.append("                    else if value of attribute \"AXTitle\" of mainWindow is not targetName then")
        lines.append("                        \(failCheck("the main window's AXTitle does not match the \(windowName) window's name"))")
        lines.append("                    end if")
        lines.append("                end if")
        lines.append("            on error errMsg")
        lines.append("                set \(failedCheckVar) to \"Mail's accessibility attributes could not be read: \" & errMsg")
        lines.append("            end try")
        lines.append("            if \(failedCheckVar) is \"\" then")
        lines.append("                \(action)")
        lines.append("                set \(actedVar) to true")
        lines.append("            end if")
        lines.append("        end tell")
        lines.append("    end tell")
        lines.append("    if not \(actedVar) then")
        lines.append("        \(focus)")
        lines += closedOnError([raise], indent: "        ")
        lines.append("        delay 0.1")
        lines.append("    end if")
        lines.append("end repeat")
        let timeoutMessage = "The \(windowName) window did not pass the key-window check within 3s; \(actionName) was not sent. Last failed check: "
        lines.append("if not \(actedVar) then error \(AppleScript.quote(timeoutMessage)) & \(failedCheckVar)")
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
