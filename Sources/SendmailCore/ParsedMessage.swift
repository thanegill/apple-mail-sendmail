import Foundation

public struct Attachment {
    public var filename: String
    public var contentType: String
    public var data: Data

    public init(filename: String, contentType: String, data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }
}

public struct ParsedMessage {
    public var subject: String = ""
    public var from: ParsedAddress? = nil
    public var to: [ParsedAddress] = []
    public var cc: [ParsedAddress] = []
    public var bcc: [ParsedAddress] = []
    /// For an HTML-only message, the tag-stripped text of `htmlBody`.
    public var body: String = ""
    public var htmlBody: String? = nil
    public var attachments: [Attachment] = []

    public init() {}
}
