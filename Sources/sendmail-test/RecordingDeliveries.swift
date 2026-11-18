import Foundation
import SendmailCore

/// Records what `MailDriver` hands the .eml path, and whether the `.eml`
/// existed at that moment.
final class RecordingEmlDelivery: EmlDelivery {
    struct Call {
        let url: URL
        let subject: String
        let send: Bool
        let emlExisted: Bool
    }

    private(set) var calls: [Call] = []
    var onDeliver: ((URL) throws -> Void)?

    func deliverEml(emlURL: URL, subject: String, send: Bool) throws {
        calls.append(Call(url: emlURL, subject: subject, send: send, emlExisted: FileManager.default.fileExists(atPath: emlURL.path)))
        try onDeliver?(emlURL)
    }
}

/// The real plain path, sending its Apple Events to `recorder` and running
/// against a fake Mail that is already running.
func recordingAutomation(_ recorder: AppleEventRecorder, eml: EmlDelivery = RecordingEmlDelivery()) -> MailAutomation {
    let mail = FakeMail()
    return MailAutomation(plain: AppleEventPlainDelivery(events: recorder, workspace: mail, clock: mail), eml: eml)
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
    /// the .eml path through `eml`.
    static func deliver(
        _ msg: ParsedMessage,
        emlBytes: Data,
        options: Options,
        tmp: TempDir,
        recorder: AppleEventRecorder,
        eml: EmlDelivery = RecordingEmlDelivery()
    ) throws {
        try deliver(msg, emlBytes: emlBytes, options: options, tmp: tmp, automation: recordingAutomation(recorder, eml: eml))
    }
}
