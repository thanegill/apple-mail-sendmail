import Foundation

let result = runSuites([
    cliTests,
    rfc822Tests,
    emlBuilderTests,
    addressTests,
    encodedWordTests,
    mimeTests,
    mailDriverTests,
    appleScriptCompileTests,
])
exit(result)
