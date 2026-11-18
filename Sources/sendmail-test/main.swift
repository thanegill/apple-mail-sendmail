import Foundation

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
    axHTMLDeliveryTests,
    failureReportTests,
    permissionCheckTests,
])
exit(result)
