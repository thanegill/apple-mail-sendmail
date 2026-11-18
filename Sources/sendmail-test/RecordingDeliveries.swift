import Foundation
import SendmailCore

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

func recordingAutomation(_ recorder: AppleEventRecorder, eml: EmlDelivery = RecordingEmlDelivery()) -> MailAutomation {
    let mail = FakeMail()
    return MailAutomation(plain: AppleEventPlainDelivery(events: recorder, workspace: mail, clock: mail), eml: eml)
}

func noUIOptions() -> Options {
    var options = Options()
    options.noUI = true
    return options
}

func plainSender(_ msg: ParsedMessage, options: Options) throws -> String? {
    let tmp = try TempDir()
    defer { tmp.cleanup() }
    let recorder = AppleEventRecorder()
    var noUI = options
    noUI.noUI = true
    try MailDriver.deliver(msg, emlBytes: Data("Subject: p\r\nContent-Type: text/plain\r\n\r\nhi".utf8), options: noUI, tmp: tmp, recorder: recorder)
    guard case let .text(sender)? = recorder.messageProperties["sndr"] else { return nil }
    return sender
}

extension MailDriver {
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
