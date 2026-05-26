// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "sendmail",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "SendmailCore",
            path: "Sources/SendmailCore"
        ),
        .executableTarget(
            name: "apple-mail-sendmail",
            dependencies: ["SendmailCore"],
            path: "Sources/apple-mail-sendmail"
        ),
        .executableTarget(
            name: "sendmail-test",
            dependencies: ["SendmailCore"],
            path: "Sources/sendmail-test"
        ),
    ]
)
