import Foundation

public enum MailDriver {
    /// `deliver`, then remove `tmp` whether delivery succeeded or threw.
    ///
    /// The executable must call this rather than relying on a top-level
    /// `defer`: its exit paths go through `exit()`, which terminates the
    /// process without unwinding top-level scope, so such a `defer` never
    /// runs and the message (eml, body, attachments) would stay on disk.
    public static func deliverThenCleanUp(
        _ msg: ParsedMessage,
        emlBytes: Data,
        options: Options,
        tmp: TempDir,
        automation: MailAutomation
    ) throws {
        defer { tmp.cleanup() }
        try deliver(msg, emlBytes: emlBytes, options: options, tmp: tmp, automation: automation)
    }

    /// `deliverThenCleanUp` through `AppleScriptMailAutomation` with
    /// `runner`; returns the script it ran.
    @discardableResult
    public static func deliverThenCleanUp(
        _ msg: ParsedMessage,
        emlBytes: Data,
        options: Options,
        tmp: TempDir,
        runner: @escaping ScriptRunner
    ) throws -> String {
        defer { tmp.cleanup() }
        return try deliver(msg, emlBytes: emlBytes, options: options, tmp: tmp, runner: runner)
    }

    /// Hand the parsed message to Mail.app.
    ///
    /// - For messages with an HTML body, write `emlBytes` to a temp `.eml`
    ///   and hand it to `automation.deliverHTML`, which opens it in Mail and
    ///   converts the viewer into a fresh editable compose with Message >
    ///   Send Again -- the only path that preserves tables, CSS padding,
    ///   monospace backgrounds, etc.
    /// - For plain-text-only messages, stage the attachments as files and
    ///   hand the rest to `automation.deliverPlain`.
    public static func deliver(
        _ msg: ParsedMessage,
        emlBytes: Data,
        options: Options,
        tmp: TempDir,
        automation: MailAutomation
    ) throws {
        if shouldUseEditDraft(msg) {
            let emlURL = try tmp.write(emlBytes, name: "compose-\(UUID().uuidString).eml")
            try automation.deliverHTML(emlURL: emlURL, send: options.send)
            return
        }

        var attachmentURLs: [URL] = []
        for (idx, att) in msg.attachments.enumerated() {
            let prefix = String(format: "att-%02d-", idx + 1)
            let safe = sanitizeFilename(att.filename, fallback: "attachment-\(idx + 1).bin")
            let url = try tmp.write(att.data, name: prefix + safe)
            attachmentURLs.append(url)
        }
        try automation.deliverPlain(PlainCompose(
            subject: msg.subject,
            sender: composeSender(options: options, headerFrom: msg.from),
            body: msg.body,
            to: msg.to,
            cc: msg.cc,
            bcc: msg.bcc,
            attachmentURLs: attachmentURLs,
            send: options.send
        ))
    }

    /// `deliver` through `AppleScriptMailAutomation` with `runner`, staging
    /// in `tmp`; returns the script it handed the runner. For a recording
    /// runner: Accessibility is not checked, since the script never runs.
    @discardableResult
    public static func deliver(
        _ msg: ParsedMessage,
        emlBytes: Data,
        options: Options,
        tmp: TempDir,
        runner: @escaping ScriptRunner
    ) throws -> String {
        var script = ""
        let automation = AppleScriptMailAutomation(staging: tmp, accessibility: .notChecked) { source in
            script = source
            try runner(source)
        }
        try deliver(msg, emlBytes: emlBytes, options: options, tmp: tmp, automation: automation)
        return script
    }

    /// True when the message has a non-empty HTML body. Drives the choice
    /// between the edit-draft path (Mail's WKWebView render) and the classic
    /// plain-text path.
    static func shouldUseEditDraft(_ msg: ParsedMessage) -> Bool {
        guard let html = msg.htmlBody else { return false }
        return !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Same precedence as `EmlBuilder.applyOverrides`: `-f` (plus `-F`)
    /// replaces the message's From; otherwise the header From is used as-is,
    /// and `-F` alone changes nothing. A header From without a domain (cron's
    /// `root (Cron Daemon)`, an empty group) cannot name a Mail account, so
    /// it is dropped and no sender is set. An explicit `-f` is never filtered.
    private static func composeSender(options: Options, headerFrom: ParsedAddress?) -> String? {
        if let address = options.fromAddress {
            return formatMailbox(name: options.fromName, address: address, for: .appleScriptSender)
        }
        guard let headerFrom, hasLocalPartAndDomain(headerFrom.address) else { return nil }
        return formatMailbox(name: headerFrom.displayName, address: headerFrom.address, for: .appleScriptSender)
    }

    private static func hasLocalPartAndDomain(_ address: String) -> Bool {
        guard let atIndex = address.lastIndex(of: "@") else { return false }
        let localPart = address[..<atIndex]
        let domain = address[address.index(after: atIndex)...]
        return !localPart.isEmpty && !domain.isEmpty
    }
}
