import Foundation

let result = runSuites([
    cliTests,
    rfc822Tests,
    addressTests,
    encodedWordTests,
    mimeTests,
    mailDriverTests,
])
exit(result)
