import Foundation
import SendmailCore

let argv0 = CommandLine.arguments.first ?? "apple-mail-sendmail"
let programName = (argv0 as NSString).lastPathComponent
let argv = Array(CommandLine.arguments.dropFirst())
let env = ProcessInfo.processInfo.environment

let options: Options
do {
    options = try CLI.parse(argv, env: env, programName: programName)
} catch let CLIError.usage(msg) {
    die(msg, code: .usage)
} catch {
    die("\(error)", code: .usage)
}

let stdinData = FileHandle.standardInput.readDataToEndOfFile()

let raw: RawMessage
do {
    raw = try RFC822Parser.parse(stdinData)
} catch {
    die("failed to parse message: \(error)", code: .dataErr)
}

var message = MIMEParser.parse(raw)

if options.readRecipientsFromHeaders {
    // -t: recipients come from headers; argv positionals are additive.
    for r in options.recipients {
        message.to.append(ParsedAddress(displayName: nil, address: r))
    }
} else {
    // Positional recipients override headers (legacy sendmail behavior).
    if !options.recipients.isEmpty {
        message.to = options.recipients.map { ParsedAddress(displayName: nil, address: $0) }
        message.cc = []
        message.bcc = []
    }
}

if message.to.isEmpty && message.cc.isEmpty && message.bcc.isEmpty {
    die("no recipients (use -t or pass them on the command line)", code: .noUser)
}

if options.fromAddress != nil {
    warn("note: Mail.app silently falls back to the default account if -f does not match an enabled account")
} else if options.fromName != nil {
    warn("note: -F was given without -f; ignoring (Mail.app needs an address to select an account)")
}

let tmp: TempDir
do {
    tmp = try TempDir()
} catch {
    // A temp-dir failure is transient (disk full, TMPDIR unwritable). Exit
    // EX_TEMPFAIL (75) so an MTA retries rather than treating it as permanent
    // (EX_OSERR 71 would be classed as a hard failure and bounced).
    die("failed to create temp dir: \(error)", code: .tempFail)
}
defer { tmp.cleanup() }

let dryRun = env["SENDMAIL_DRY_RUN"] == "1"
let runner: ScriptRunner? = dryRun ? { script in
    FileHandle.standardOutput.write(Data(script.utf8))
    FileHandle.standardOutput.write(Data("\n".utf8))
} : nil

// Build the .eml bytes that the edit-draft path will hand to Mail. Keep
// the original stdin body verbatim (no MIME re-encoding) and apply CLI
// flag-driven header overrides only: finalize To/Cc/Bcc per positional/-t
// rules and set From from -f/-F. MIMEParser already gave us the final
// recipients on `message`; EmlBuilder applies them to `raw`.
let emlBytes = EmlBuilder.buildEml(
    raw: raw,
    finalRecipients: message,
    options: options
)

do {
    try MailDriver.deliver(message, emlBytes: emlBytes, options: options, tmp: tmp, runner: runner)
} catch let f as AppleScript.Failure {
    if f.code == -1743 {
        die("Mail.app automation denied. Grant permission in System Settings → Privacy & Security → Automation. (\(f.message))", code: .config)
    }
    die("AppleScript failed (\(f.code)): \(f.message)", code: .osErr)
} catch {
    die("delivery failed: \(error)", code: .osErr)
}

exit(ExitCode.ok.rawValue)
