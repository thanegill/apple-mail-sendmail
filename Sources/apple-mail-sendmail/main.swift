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
    die("failed to create temp dir: \(error)", code: .osErr)
}
defer { tmp.cleanup() }

let dryRun = env["SENDMAIL_DRY_RUN"] == "1"
let runner: ScriptRunner? = dryRun ? { script in
    FileHandle.standardOutput.write(Data(script.utf8))
    FileHandle.standardOutput.write(Data("\n".utf8))
} : nil

do {
    try MailDriver.deliver(message, options: options, tmp: tmp, runner: runner)
} catch let f as AppleScript.Failure {
    if f.code == -1743 {
        die("Mail.app automation denied. Grant permission in System Settings → Privacy & Security → Automation. (\(f.message))", code: .config)
    }
    die("AppleScript failed (\(f.code)): \(f.message)", code: .osErr)
} catch {
    die("delivery failed: \(error)", code: .osErr)
}

exit(ExitCode.ok.rawValue)
