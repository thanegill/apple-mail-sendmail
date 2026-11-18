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

extension MailDriver {
    /// `deliver` with the plain path through the real AppleScript emitter and
    /// `runner`, and the HTML path through `html`. Returns the plain path's
    /// script, or "" when the message took the HTML path.
    @discardableResult
    static func deliver(
        _ msg: ParsedMessage,
        emlBytes: Data,
        options: Options,
        tmp: TempDir,
        runner: @escaping ScriptRunner,
        html: HTMLDelivery = RecordingHTMLDelivery()
    ) throws -> String {
        var script = ""
        let plain = AppleScriptPlainDelivery(staging: tmp) { source in
            script = source
            try runner(source)
        }
        try deliver(msg, emlBytes: emlBytes, options: options, tmp: tmp, automation: MailAutomation(plain: plain, html: html))
        return script
    }
}
