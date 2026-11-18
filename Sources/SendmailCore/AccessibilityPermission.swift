import ApplicationServices
import Foundation

/// Whether this process may drive another app's UI, which the HTML path
/// needs and the plain path does not. TCC charges the grant to the
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

    /// For a run that reaches no app at all (the dry run, a recording
    /// runner), so there is nothing to grant.
    public static let notChecked = AccessibilityPermission(osMajorVersion: 0) { true }

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
        "Accessibility permission required for HTML messages. Grant it to the app that runs apple-mail-sendmail (for example your terminal) in \(settingsLocation)."
    }
}
