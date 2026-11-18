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

    /// Hand the parsed message to Mail.app.
    ///
    /// - By default, write `emlBytes` to a temp `.eml` and hand it to
    ///   `automation.eml`, which opens it in Mail and converts the viewer
    ///   into a fresh editable compose with Message > Send Again. This is
    ///   the only path that preserves an HTML body's tables, CSS padding,
    ///   monospace backgrounds, etc., and the only one on which Mail sends
    ///   a plain-text body as written: a body set through Apple Events goes
    ///   out as a quotation (FB11734014).
    /// - With `options.noUI`, stage the attachments as files and hand a
    ///   plain-text message to `automation.plain`. A message with an HTML
    ///   body is refused with `HTMLNeedsUI` before anything is written.
    public static func deliver(
        _ msg: ParsedMessage,
        emlBytes: Data,
        options: Options,
        tmp: TempDir,
        automation: MailAutomation
    ) throws {
        try requireDeliverable(msg, options: options)
        guard options.noUI else {
            let emlURL = try tmp.write(emlBytes, name: "compose-\(UUID().uuidString).eml")
            try automation.eml.deliverEml(emlURL: emlURL, subject: msg.subject, send: options.send)
            return
        }

        var attachmentURLs: [URL] = []
        for (idx, att) in msg.attachments.enumerated() {
            let prefix = String(format: "att-%02d-", idx + 1)
            let safe = sanitizeFilename(att.filename, fallback: "attachment-\(idx + 1).bin")
            let url = try tmp.write(att.data, name: prefix + safe)
            attachmentURLs.append(url)
        }
        try automation.plain.deliverPlain(PlainCompose(
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

    /// Throws for a message `deliver` would refuse, so the executable can
    /// stop before it creates a temp dir: `HTMLNeedsUI` for an HTML body with
    /// `--no-ui`, and `SendNeedsSubject` for `--send` without a Subject.
    public static func requireDeliverable(_ msg: ParsedMessage, options: Options) throws {
        if options.noUI && hasHTMLBody(msg) {
            throw HTMLNeedsUI()
        }
        if options.send && msg.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SendNeedsSubject()
        }
    }

    /// True when the message has a non-empty HTML body, which only the .eml
    /// path can deliver.
    static func hasHTMLBody(_ msg: ParsedMessage) -> Bool {
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
            return formatMailbox(name: options.fromName, address: address, for: .mailSender)
        }
        guard let headerFrom, hasLocalPartAndDomain(headerFrom.address) else { return nil }
        return formatMailbox(name: headerFrom.displayName, address: headerFrom.address, for: .mailSender)
    }

    private static func hasLocalPartAndDomain(_ address: String) -> Bool {
        guard let atIndex = address.lastIndex(of: "@") else { return false }
        let localPart = address[..<atIndex]
        let domain = address[address.index(after: atIndex)...]
        return !localPart.isEmpty && !domain.isEmpty
    }
}

/// `--no-ui` was asked to deliver a message with an HTML body. Only the .eml
/// path renders HTML, and it works through Mail's windows and menus.
public struct HTMLNeedsUI: Error, CustomStringConvertible, Equatable {
    public init() {}

    public var description: String {
        "--no-ui (or SENDMAIL_NO_UI=1) cannot deliver a message with an HTML body: only the default path, which works through Mail's windows and needs Accessibility, renders HTML. Nothing was sent. Run without --no-ui, or send a text/plain message."
    }
}

/// `--send` was asked for a message whose decoded Subject is empty or only
/// whitespace. Mail holds such a message for a "no subject, send anyway?"
/// confirmation: the .eml path's compose shows it as a sheet the binary never
/// answers, and a `--no-ui` message, which has no window, keeps it invisible
/// in `outgoing messages` and never sends it, though `send` reports success.
public struct SendNeedsSubject: Error, CustomStringConvertible, Equatable {
    public init() {}

    public var description: String {
        "--send needs a non-empty Subject: Mail holds a message without one for a confirmation it can't show from here, so it would not be sent. Nothing was sent. Add a Subject header, or leave out --send to get a draft."
    }
}
