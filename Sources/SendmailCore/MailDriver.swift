import Foundation

public enum MailDriver {
    /// The executable must call this, not use a top-level `defer`: its exit
    /// paths call `exit()`, which never runs one, leaving the message on disk.
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

    /// The .eml path is the only one that keeps an HTML body's layout, and
    /// the only one on which Mail sends a plain-text body as written: a body
    /// set through Apple Events goes out as a quotation (FB11734014).
    /// Attachments ride inside the .eml (verified live 2026-07-09).
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

    /// Lets the executable refuse before it creates a temp dir.
    public static func requireDeliverable(_ msg: ParsedMessage, options: Options) throws {
        if options.noUI && hasHTMLBody(msg) {
            throw HTMLNeedsUI()
        }
        if options.send && msg.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SendNeedsSubject()
        }
    }

    static func hasHTMLBody(_ msg: ParsedMessage) -> Bool {
        guard let html = msg.htmlBody else { return false }
        return !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Keep the precedence in step with `EmlBuilder.applyOverrides`. A header
    /// From without a domain (cron's `root (Cron Daemon)`) cannot name a Mail
    /// account, so no sender is set; an explicit `-f` is never filtered.
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

public struct HTMLNeedsUI: Error, CustomStringConvertible, Equatable {
    public init() {}

    public var description: String {
        "--no-ui (or SENDMAIL_NO_UI=1) cannot deliver a message with an HTML body: only the default path, which works through Mail's windows and needs Accessibility, renders HTML. Nothing was sent. Run without --no-ui, or send a text/plain message."
    }
}

/// Mail holds a message with no Subject for a "send anyway?" confirmation:
/// the .eml path's compose shows it as a sheet the binary never answers, and
/// a `--no-ui` message, which has no window, stays invisible in `outgoing
/// messages` and is never sent, though `send` reports success.
public struct SendNeedsSubject: Error, CustomStringConvertible, Equatable {
    public init() {}

    public var description: String {
        "--send needs a non-empty Subject: Mail holds a message without one for a confirmation it can't show from here, so it would not be sent. Nothing was sent. Add a Subject header, or leave out --send to get a draft."
    }
}
