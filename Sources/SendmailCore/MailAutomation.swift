import Foundation

/// A plain-text message, ready for Mail: recipients finalized, sender chosen,
/// attachments already staged as files.
public struct PlainCompose {
    public var subject: String
    /// The `sender` Mail should use to pick the account, or nil to leave Mail
    /// on its default account.
    public var sender: String?
    public var body: String
    public var to: [ParsedAddress]
    public var cc: [ParsedAddress]
    public var bcc: [ParsedAddress]
    public var attachmentURLs: [URL]
    /// Send at once instead of leaving a visible draft.
    public var send: Bool

    public init(
        subject: String,
        sender: String?,
        body: String,
        to: [ParsedAddress],
        cc: [ParsedAddress],
        bcc: [ParsedAddress],
        attachmentURLs: [URL],
        send: Bool
    ) {
        self.subject = subject
        self.sender = sender
        self.body = body
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.attachmentURLs = attachmentURLs
        self.send = send
    }
}

/// Creates an outgoing message in Mail from a `PlainCompose`: a visible
/// draft, or sent at once when `compose.send` is true.
public protocol PlainDelivery {
    func deliverPlain(_ compose: PlainCompose) throws
}

/// Opens the `.eml` at `emlURL` in Mail and turns it into a new compose
/// with Message > Send Again; with `send`, also sends that compose.
/// `subject` is the message's decoded Subject, which Mail shows as the
/// viewer's and the compose's title.
public protocol EmlDelivery {
    func deliverEml(emlURL: URL, subject: String, send: Bool) throws
}

/// How the binary drives Mail.app, one implementation per path. `MailDriver`
/// decides which path a message takes and stages its files; the deliveries
/// only talk to Mail.
///
/// Anything new that drives Mail goes behind these protocols, so tests can
/// substitute a recorder and never launch Mail.
public struct MailAutomation {
    public var plain: PlainDelivery
    public var eml: EmlDelivery

    public init(plain: PlainDelivery, eml: EmlDelivery) {
        self.plain = plain
        self.eml = eml
    }
}
