import ApplicationServices
import Foundation

/// Whether this process may drive another app's UI, which the .eml path
/// needs and `--no-ui`'s Apple Event path does not. TCC charges the grant to the
/// responsible process (the terminal, or whatever launched the binary).
public struct AccessibilityPermission {
    let isGranted: () -> Bool
    let osMajorVersion: Int

    public init(osMajorVersion: Int, isGranted: @escaping () -> Bool) {
        self.osMajorVersion = osMajorVersion
        self.isGranted = isGranted
    }

    /// The real check, `AXIsProcessTrusted()`, which never prompts.
    public static func system() -> AccessibilityPermission {
        AccessibilityPermission(osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
            AXIsProcessTrusted()
        }
    }

    public func require() throws {
        guard isGranted() else { throw AccessibilityNotGranted(osMajorVersion: osMajorVersion) }
    }
}

public struct AccessibilityNotGranted: Error, CustomStringConvertible {
    public let osMajorVersion: Int

    public init(osMajorVersion: Int) {
        self.osMajorVersion = osMajorVersion
    }

    /// macOS 27 renamed the Accessibility pane.
    public var settingsLocation: String {
        osMajorVersion >= 27
            ? "System Settings > Privacy & Security > Device Control and Data Access"
            : "System Settings > Privacy & Security > Accessibility"
    }

    public var description: String {
        "Accessibility permission required: apple-mail-sendmail opens each message in Mail and presses Message > Send Again. Grant it to the app that runs apple-mail-sendmail (for example your terminal) in \(settingsLocation). For a plain-text message where that is not possible, --no-ui sends through Apple Events instead (needs Automation for Mail; Mail then sends the body quoted)."
    }
}
