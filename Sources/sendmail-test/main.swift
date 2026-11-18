import Foundation

let testArguments = CommandLine.arguments.dropFirst()
if testArguments.first == "--parse-dump" {
    exit(ParseDump.run(paths: Array(testArguments.dropFirst())))
}

let result = runSuites([
    cliTests,
    rfc822Tests,
    emlBuilderTests,
    mailboxFormatTests,
    addressTests,
    encodedWordTests,
    mimeTests,
    mailDriverTests,
    accessibilityTests,
    axEmlDeliveryTests,
    failureReportTests,
    permissionCheckTests,
])
exit(result)
