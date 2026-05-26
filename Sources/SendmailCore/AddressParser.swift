import Foundation

public struct ParsedAddress {
    public var displayName: String?
    public var address: String

    public init(displayName: String?, address: String) {
        self.displayName = displayName
        self.address = address
    }
}

public enum AddressParser {
    /// Split a header value like `"Alice" <a@x>, b@y (Bob), Carol <c@z>` into
    /// individual addresses, then parse each. Comments in parentheses are
    /// stripped; quoted-string display names are honored.
    public static func parse(_ value: String) -> [ParsedAddress] {
        let tokens = split(value)
        return tokens.compactMap { parseOne($0) }
    }

    private static func split(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        var angle = 0
        var paren = 0
        var escape = false
        for ch in s {
            if escape {
                current.append(ch)
                escape = false
                continue
            }
            if ch == "\\" {
                escape = true
                current.append(ch)
                continue
            }
            if !inQuotes && paren == 0 {
                if ch == "\"" { inQuotes = true; current.append(ch); continue }
                if ch == "<" { angle += 1; current.append(ch); continue }
                if ch == ">" { angle = max(0, angle - 1); current.append(ch); continue }
                if ch == "(" { paren += 1; current.append(ch); continue }
                if ch == "," && angle == 0 {
                    out.append(current)
                    current = ""
                    continue
                }
                current.append(ch)
                continue
            }
            if inQuotes {
                if ch == "\"" { inQuotes = false }
                current.append(ch)
                continue
            }
            if paren > 0 {
                if ch == "(" { paren += 1 }
                if ch == ")" { paren -= 1 }
                current.append(ch)
                continue
            }
            current.append(ch)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(current)
        }
        return out
    }

    private static func parseOne(_ raw: String) -> ParsedAddress? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }

        // Strip comments in parentheses (not nested in quotes).
        var noComments = ""
        var inQuotes = false
        var paren = 0
        for ch in trimmed {
            if !inQuotes {
                if ch == "\"" { inQuotes = true; noComments.append(ch); continue }
                if ch == "(" { paren += 1; continue }
                if ch == ")" { paren = max(0, paren - 1); continue }
                if paren == 0 { noComments.append(ch) }
                continue
            }
            if ch == "\"" { inQuotes = false }
            noComments.append(ch)
        }

        let s = noComments.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }

        if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
            let addr = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            var name = String(s[..<lt]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 {
                name = String(name.dropFirst().dropLast())
            }
            let decoded = EncodedWord.decode(name)
            return ParsedAddress(displayName: decoded.isEmpty ? nil : decoded, address: addr)
        }
        return ParsedAddress(displayName: nil, address: s)
    }
}
