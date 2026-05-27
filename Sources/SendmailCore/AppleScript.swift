import Foundation
#if canImport(AppKit)
import AppKit
#endif

public enum AppleScript {
    public struct Failure: Error {
        public var code: Int
        public var message: String

        public init(code: Int, message: String) {
            self.code = code
            self.message = message
        }
    }

    /// Run an AppleScript source string via NSAppleScript. Returns the result
    /// descriptor (typically empty) on success, throws Failure on error.
    public static func run(_ source: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw Failure(code: 0, message: "failed to construct NSAppleScript")
        }
        var errorInfo: NSDictionary? = nil
        _ = script.executeAndReturnError(&errorInfo)
        if let err = errorInfo as? [String: Any] {
            let num = (err["NSAppleScriptErrorNumber"] as? Int)
                ?? (err[NSAppleScript.errorNumber] as? Int)
                ?? 0
            let msg = (err["NSAppleScriptErrorMessage"] as? String)
                ?? (err[NSAppleScript.errorMessage] as? String)
                ?? "AppleScript execution failed"
            throw Failure(code: num, message: msg)
        }
    }

    /// Escape a string for embedding inside an AppleScript double-quoted literal.
    /// Wraps the result in double quotes. Newlines, tabs, and returns are
    /// escaped so the literal stays single-line; AppleScript decodes `\n`,
    /// `\r`, `\t` per the language reference.
    public static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        out += "\""
        return out
    }
}
