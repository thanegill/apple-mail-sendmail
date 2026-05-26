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
    public var to: [ParsedAddress] = []
    public var cc: [ParsedAddress] = []
    public var bcc: [ParsedAddress] = []
    public var body: String = ""
    public var attachments: [Attachment] = []

    public init() {}
}
