import Foundation
import SendmailCore

/// Records what `MailDriver` hands the HTML path, and whether the `.eml`
/// existed at that moment.
final class RecordingHTMLDelivery: HTMLDelivery {
    struct Call {
        let url: URL
        let send: Bool
        let emlExisted: Bool
    }

    private(set) var calls: [Call] = []
    var onDeliver: ((URL) throws -> Void)?

    func deliverHTML(emlURL: URL, send: Bool) throws {
        calls.append(Call(url: emlURL, send: send, emlExisted: FileManager.default.fileExists(atPath: emlURL.path)))
        try onDeliver?(emlURL)
    }
}

/// The real plain path, sending its Apple Events to `recorder` and running
/// against a fake Mail that is already running.
func recordingAutomation(_ recorder: AppleEventRecorder, html: HTMLDelivery = RecordingHTMLDelivery()) -> MailAutomation {
    let mail = FakeMail()
    return MailAutomation(plain: AppleEventPlainDelivery(events: recorder, workspace: mail, clock: mail), html: html)
}

/// The `sender` the plain path gives Mail for `msg`, or nil if it sets none.
func plainSender(_ msg: ParsedMessage, options: Options) throws -> String? {
    let tmp = try TempDir()
    defer { tmp.cleanup() }
    let recorder = AppleEventRecorder()
    try MailDriver.deliver(msg, emlBytes: Data("Subject: p\r\nContent-Type: text/plain\r\n\r\nhi".utf8), options: options, tmp: tmp, recorder: recorder)
    guard case let .text(sender)? = recorder.messageProperties["sndr"] else { return nil }
    return sender
}

extension MailDriver {
    /// `deliver` with the plain path's Apple Events going to `recorder`, and
    /// the HTML path through `html`.
    static func deliver(
        _ msg: ParsedMessage,
        emlBytes: Data,
        options: Options,
        tmp: TempDir,
        recorder: AppleEventRecorder,
        html: HTMLDelivery = RecordingHTMLDelivery()
    ) throws {
        try deliver(msg, emlBytes: emlBytes, options: options, tmp: tmp, automation: recordingAutomation(recorder, html: html))
    }
}
