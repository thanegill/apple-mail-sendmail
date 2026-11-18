import AppKit
import Foundation
import SendmailCore

/// A script handed to a recording `ScriptRunner`, tagged with the test that
/// produced it so a compile failure names its origin.
struct CapturedScript {
    let testName: String
    let source: String
}

/// Every script the MailDriver suite's recording runners captured. The
/// AppleScriptCompile suite compiles them, so it must run after MailDriver.
var capturedMailDriverScripts: [CapturedScript] = []

struct AppleScriptCompileError {
    let number: Int
    let message: String
    let lineNumber: Int
    let offendingLine: String

    var description: String {
        "error \(number): \(message)\n      line \(lineNumber): \(offendingLine)"
    }
}

/// Compile `source` without executing it. Returns nil on success.
///
/// Compiling resolves application terms from the target app's scripting
/// definition. For an app with a static sdef (`OSAScriptingDefinition` in
/// Info.plist) the compiler reads the file and neither launches the app nor
/// sends it an AppleEvent; `requireAppleScriptCompiler` enforces that before
/// any Mail or System Events terms are compiled.
func compileAppleScript(_ source: String) -> AppleScriptCompileError? {
    guard let script = NSAppleScript(source: source) else {
        return AppleScriptCompileError(number: 0, message: "NSAppleScript(source:) returned nil", lineNumber: 0, offendingLine: "")
    }
    var errorInfo: NSDictionary?
    if script.compileAndReturnError(&errorInfo) { return nil }

    let info = errorInfo as? [String: Any] ?? [:]
    let number = info[NSAppleScript.errorNumber] as? Int ?? 0
    let message = info[NSAppleScript.errorMessage] as? String ?? "compilation failed"
    let errorRange = (info[NSAppleScript.errorRange] as? NSValue)?.rangeValue
    let (lineNumber, offendingLine) = lineContaining(utf16Offset: errorRange?.location ?? 0, in: source)
    return AppleScriptCompileError(number: number, message: message, lineNumber: lineNumber, offendingLine: offendingLine)
}

private func lineContaining(utf16Offset: Int, in source: String) -> (Int, String) {
    let utf16 = source.utf16
    let clampedOffset = min(max(utf16Offset, 0), utf16.count)
    let errorIndex = utf16.index(utf16.startIndex, offsetBy: clampedOffset)
    let lineNumber = source[..<errorIndex].filter(\.isNewline).count + 1
    let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    let offendingLine = lineNumber <= lines.count ? String(lines[lineNumber - 1]) : ""
    return (lineNumber, offendingLine.trimmingCharacters(in: .whitespaces))
}

/// AppleScript syntax errors are -2700 ... -2799.
private func isSyntaxError(_ error: AppleScriptCompileError) -> Bool {
    (-2799 ... -2700).contains(error.number)
}

/// The only condition that skips the suite: the compiler itself cannot load,
/// so even a script with no application terms fails. Observed under
/// `sandbox = true` as error -2147450879.
private let compilerUnavailableReason: String? = {
    guard let bareError = compileAppleScript("return 1") else { return nil }
    return "the AppleScript compiler is unavailable here: error \(bareError.number) \(bareError.message)"
}()

/// Apps whose terms the emitted scripts use. Compiling against an app without
/// a static `OSAScriptingDefinition` launches it to fetch its terminology, so
/// each must declare one before anything referencing it is compiled.
private let scriptedApps: [(name: String, bundleID: String)] = [
    ("Mail", "com.apple.mail"),
    ("System Events", "com.apple.systemevents"),
]

private let missingStaticSdefFailure: String? = {
    for app in scriptedApps {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
            return "Launch Services cannot resolve \(app.bundleID); refusing to compile \(app.name) terms"
        }
        let sdefName = Bundle(url: appURL)?.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String
        if sdefName == nil {
            return "\(appURL.path) declares no OSAScriptingDefinition, so compiling \(app.name) terms would launch it; refusing to compile"
        }
    }
    return nil
}()

private let mailTermsProbeFailure: String? = {
    let probe = "tell application \"Mail\" to make new outgoing message with properties {visible:false}"
    guard let probeError = compileAppleScript(probe) else { return nil }
    return "Mail's terms did not load (Launch Services could not resolve com.apple.mail, or Mail's dictionary changed): \(probeError.description)"
}()

/// Skip only when the compiler cannot load at all; every other environment
/// problem is a failure, so a Mail dictionary regression cannot hide as a skip.
private func requireAppleScriptCompiler(file: StaticString = #file, line: UInt = #line) throws {
    if let reason = compilerUnavailableReason { try skip(reason) }
    if let failure = missingStaticSdefFailure ?? mailTermsProbeFailure {
        throw TestFailure(message: failure, file: file, line: line)
    }
}

private func expectCompiles(_ source: String, origin: String, file: StaticString = #file, line: UInt = #line) throws {
    guard let error = compileAppleScript(source) else { return }
    throw TestFailure(message: "\(origin) does not compile: \(error.description)", file: file, line: line)
}

private final class CompileRecorder {
    var scripts: [String] = []
    func run(_ source: String) throws { scripts.append(source) }
}

private func emitScript(_ msg: ParsedMessage, send: Bool, emlBytes: Data = Data("Subject: x\r\n\r\nx".utf8)) throws -> String {
    let tmp = try TempDir()
    defer { tmp.cleanup() }
    var opts = Options()
    opts.send = send
    opts.fromName = "Ops \"Bot\" \\ Café"
    opts.fromAddress = "bot@example.com"
    return try MailDriver.deliver(msg, emlBytes: emlBytes, options: opts, tmp: tmp, runner: CompileRecorder().run)
}

private let oddSubjects: [(label: String, subject: String)] = [
    ("empty", ""),
    ("quotes_and_backslashes", "He said \"hi\" \\ C:\\path\\"),
    ("non_ascii", "Caf\u{e9} \u{2014} \u{65e5}\u{672c}\u{8a9e} \u{1F44B}"),
    // Checks only that the result compiles. It cannot catch a raw CRLF passing
    // through AppleScript.quote: AppleScript accepts raw line breaks inside a
    // string literal, so the script compiles either way.
    ("crlf_from_encoded_word", EncodedWord.decode("=?UTF-8?Q?line1=0D=0Aline2=0Dline3=0Aend?=")),
    ("line_and_paragraph_separators", "before\u{2028}after\u{2029}end"),
    ("c0_controls_and_tab", "a\u{0}b\u{7}c\td\u{1b}e"),
    ("applescript_lookalikes", "end tell\" & (do shell script \"echo pwned\") & \""),
]

private let oddRecipients: [ParsedAddress] = [
    ParsedAddress(displayName: "Alice \"Al\" O'Neil", address: "alice@example.com"),
    ParsedAddress(displayName: "J\u{f6}rg \\ M\u{fc}ller", address: "jorg@example.de"),
    ParsedAddress(displayName: nil, address: "bare@example.com"),
]

let appleScriptCompileTests = TestSuite(name: "AppleScriptCompile", cases: [
    TestCase(name: "every_script_captured_from_maildriver_suite_compiles") {
        try requireAppleScriptCompiler()
        let missingCaptureHint = "the MailDriver suite must run before this one"
        try expect(capturedMailDriverScripts.contains { $0.source.contains("click menu item \"Send Again\"") }, "no edit-draft script captured; \(missingCaptureHint)")
        try expect(capturedMailDriverScripts.contains { $0.source.contains("make new outgoing message") }, "no classic script captured; \(missingCaptureHint)")
        var failures: [String] = []
        for captured in capturedMailDriverScripts {
            if let error = compileAppleScript(captured.source) {
                failures.append("\(captured.testName): \(error.description)")
            }
        }
        try expect(failures.isEmpty, "\(failures.count) of \(capturedMailDriverScripts.count) captured scripts do not compile:\n    " + failures.joined(separator: "\n    "))
    },

    TestCase(name: "classic_script_compiles_across_send_attachment_and_subject_variants") {
        try requireAppleScriptCompiler()
        for send in [false, true] {
            for withAttachments in [false, true] {
                for (label, subject) in oddSubjects {
                    var msg = ParsedMessage()
                    msg.subject = subject
                    msg.to = oddRecipients
                    msg.cc = [oddRecipients[0]]
                    msg.bcc = [oddRecipients[1]]
                    msg.body = "body with \"quotes\" and \\backslashes"
                    if withAttachments {
                        msg.attachments = [
                            Attachment(filename: "r\u{e9}sum\u{e9} \"final\".pdf", contentType: "application/pdf", data: Data("%PDF".utf8)),
                            Attachment(filename: "", contentType: "application/octet-stream", data: Data([0, 1, 2])),
                        ]
                    }
                    let script = try emitScript(msg, send: send)
                    try expect(script.contains("make new outgoing message"), "expected the classic emitter")
                    try expectCompiles(script, origin: "classic send=\(send) attachments=\(withAttachments) subject=\(label)")
                }
            }
        }
    },

    TestCase(name: "edit_draft_script_compiles_for_send_and_draft_with_odd_eml_paths") {
        // The edit-draft script depends only on the .eml path and the send
        // flag, so those are the inputs to vary.
        try requireAppleScriptCompiler()
        let emlPaths = [
            "/tmp/plain/compose.eml",
            "/tmp/odd \"dir\" \\ caf\u{e9} \u{65e5}\u{672c}/compose \"x\".eml",
        ]
        for send in [false, true] {
            for emlPath in emlPaths {
                let script = MailDriver.buildEditDraftScript(emlPath: emlPath, send: send)
                try expectCompiles(script, origin: "edit-draft send=\(send) emlPath=\(emlPath)")
            }
        }
    },

    TestCase(name: "missing_end_tell_fails_to_compile") {
        try requireAppleScriptCompiler()
        let broken = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject:"x", visible:true}
        """
        let error = compileAppleScript(broken)
        try expectNotNil(error)
        try expect(isSyntaxError(error!), "expected a syntax error, got \(error!.description)")
    },

    TestCase(name: "mail_terms_fail_to_compile_outside_a_mail_tell_block") {
        // Proves the check consults Mail's dictionary: the same statement the
        // classic emitter produces is a syntax error against another app's.
        try requireAppleScriptCompiler()
        let mailStatement = "make new to recipient at end of to recipients with properties {address:\"a@b\"}"
        try expectCompiles("tell application \"Mail\"\n    \(mailStatement)\nend tell", origin: "Mail control")
        let error = compileAppleScript("tell application \"System Events\"\n    \(mailStatement)\nend tell")
        try expectNotNil(error)
        try expectEqual(error!.lineNumber, 2)
    },
])
