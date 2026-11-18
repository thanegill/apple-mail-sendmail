import Foundation
import os
import SendmailCore

let argv0 = CommandLine.arguments.first ?? "apple-mail-sendmail"
let programName = (argv0 as NSString).lastPathComponent
let argv = Array(CommandLine.arguments.dropFirst())
let env = ProcessInfo.processInfo.environment

let options: Options
do {
    options = try CLI.parse(argv, env: env)
} catch let CLIError.usage(msg) {
    die(msg, code: .usage)
} catch {
    die("\(error)", code: .usage)
}

switch options.infoRequest {
case .help:
    CLI.printHelp(programName: programName)
    exit(ExitCode.ok.rawValue)
case .version:
    print(CLI.versionText)
    exit(ExitCode.ok.rawValue)
case .checkPermissions:
    if env["SENDMAIL_DRY_RUN"] == "1" {
        die("--check-permissions is not available with SENDMAIL_DRY_RUN=1: it starts Mail and may show a permission prompt", code: .usage)
    }
    let clock = SystemClock()
    let report = PermissionCheck.run(
        probe: SystemPermissionProbe(),
        workspace: SystemMailWorkspace(clock: clock),
        clock: clock,
        osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    )
    print(report.text)
    exit(report.exitCode.rawValue)
case nil:
    break
}

let stdinData = FileHandle.standardInput.readDataToEndOfFile()

let raw: RawMessage
do {
    raw = try RFC822Parser.parse(stdinData)
} catch {
    die("failed to parse message: \(error)", code: .dataErr)
}

var message = MIMEParser.parse(raw)

do {
    try MailDriver.requireDeliverable(message, options: options)
} catch {
    let report = FailureReport(error)
    die(report.message, code: report.exitCode)
}

if options.readRecipientsFromHeaders {
    // Deliberately additive, unlike real sendmail, whose -t REMOVES argv
    // addresses from the header recipients; changing that is a product decision.
    var seen = Set(
        (message.to + message.cc + message.bcc).map { $0.address.lowercased() }
    )
    for r in options.recipients {
        let key = r.lowercased()
        if seen.contains(key) { continue }
        seen.insert(key)
        message.to.append(ParsedAddress(displayName: nil, address: r))
    }
} else {
    // As in sendmail, without -t header Cc/Bcc are not delivered to when argv
    // names recipients.
    if !options.recipients.isEmpty {
        message.to = options.recipients.map { ParsedAddress(displayName: nil, address: $0) }
        message.cc = []
        message.bcc = []
    }
}

if message.to.isEmpty && message.cc.isEmpty && message.bcc.isEmpty {
    die("no recipients: To/Cc/Bcc held no addresses and none were given on the command line", code: .noUser)
}

if options.fromAddress != nil {
    warn("note: Mail.app silently falls back to the default account if -f does not match an enabled account")
} else if options.fromName != nil {
    warn("note: -F was given without -f; ignoring (the message's From header, if any, is used unchanged)")
}

let tmp: TempDir
do {
    tmp = try TempDir()
} catch {
    // Transient (disk full, TMPDIR unwritable): EX_TEMPFAIL makes an MTA
    // retry, where EX_OSERR would bounce.
    die("failed to create temp dir: \(error)", code: .tempFail)
}

func printLine(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

let automation: MailAutomation
if env["SENDMAIL_DRY_RUN"] == "1" {
    automation = MailAutomation(
        plain: PlainPlanPrinter(output: printLine),
        eml: EmlPlanPrinter(output: printLine)
    )
} else {
    let clock = SystemClock()
    let workspace = SystemMailWorkspace(clock: clock)
    let emlLog = Logger(subsystem: "apple-mail-sendmail", category: "eml")
    automation = MailAutomation(
        plain: AppleEventPlainDelivery(events: SystemAppleEventSender(), workspace: workspace, clock: clock),
        eml: AXEmlDelivery(
            ax: SystemAXClient(),
            workspace: workspace,
            clock: clock,
            accessibility: .system(),
            trace: { emlLog.notice("\($0, privacy: .public)") }
        )
    )
}

let emlBytes = EmlBuilder.buildEml(
    raw: raw,
    finalRecipients: message,
    options: options
)

do {
    try MailDriver.deliverThenCleanUp(message, emlBytes: emlBytes, options: options, tmp: tmp, automation: automation)
} catch {
    let report = FailureReport(error)
    die(report.message, code: report.exitCode)
}

exit(ExitCode.ok.rawValue)
