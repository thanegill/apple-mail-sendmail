import Foundation

public struct PlainCompose {
    public var subject: String
    public var sender: String?
    public var body: String
    public var to: [ParsedAddress]
    public var cc: [ParsedAddress]
    public var bcc: [ParsedAddress]
    public var attachmentURLs: [URL]
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

public protocol PlainDelivery {
    func deliverPlain(_ compose: PlainCompose) throws
}

/// `subject` is the decoded Subject, which Mail shows as the viewer's and
/// the compose's title.
public protocol EmlDelivery {
    func deliverEml(emlURL: URL, subject: String, send: Bool) throws
}

/// Anything new that drives Mail goes behind these protocols, so tests can
/// substitute a recorder or fake and never launch Mail.
public struct MailAutomation {
    public var plain: PlainDelivery
    public var eml: EmlDelivery

    public init(plain: PlainDelivery, eml: EmlDelivery) {
        self.plain = plain
        self.eml = eml
    }
}
