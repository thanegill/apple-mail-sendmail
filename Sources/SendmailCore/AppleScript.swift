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
    ///
    /// U+2028 (LINE SEPARATOR) and U+2029 (PARAGRAPH SEPARATOR) can survive
    /// RFC 2047 decoding into a Subject or display name. It is unverified
    /// whether NSAppleScript's parser treats them as line terminators, so we
    /// defensively map them to an escaped `\n` -- the same representation as a
    /// literal newline -- rather than pass the raw code point through where it
    /// could split the double-quoted literal. Other C0 control characters
    /// (except the `\n`/`\r`/`\t` already handled above) are mapped to a space
    /// for the same reason; this is cheap and keeps normal ASCII unchanged.
    public static func quote(_ s: String) -> String {
        var out = "\""
        // NB: iterate scalars, not Characters. A `"` or `\` fused with a
        // combining mark (or "\r\n") is one Character that matches no case
        // below, so it would pass through unescaped and end the literal.
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}", "\u{2029}": out += "\\n"
            case _ where scalar.value < 0x20: out += " "
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }
}
