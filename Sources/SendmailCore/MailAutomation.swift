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

/// How the binary drives Mail.app. `MailDriver` decides which path a message
/// takes and stages its files; an implementation only talks to Mail.
///
/// Anything new that drives Mail goes behind this protocol, so tests can
/// substitute a recorder and never launch Mail.
public protocol MailAutomation {
    /// Create an outgoing message from `compose`: a visible draft, or sent
    /// at once when `compose.send` is true.
    func deliverPlain(_ compose: PlainCompose) throws

    /// Open the `.eml` at `emlURL` in Mail and turn it into a new compose
    /// with Message > Send Again; with `send`, also send that compose.
    func deliverHTML(emlURL: URL, send: Bool) throws
}
