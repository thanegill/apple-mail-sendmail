import Foundation

public struct ParsedAddress {
    public var displayName: String?
    public var address: String

    public init(displayName: String?, address: String) {
        self.displayName = displayName
        self.address = address
    }
}

enum MailboxFormatTarget {
    case rfc822Header
    /// Mail encodes headers itself on send, so non-ASCII stays literal;
    /// pre-encoding it would risk Mail treating the encoded-word as text.
    case mailSender
}

/// Shared by the `--no-ui` path's `sender`, the .eml `From` override and the
/// .eml To/Cc/Bcc, so all three stay in lockstep. A name with anything
/// outside `atext` and space is quoted, or a re-parser would split it; so
/// is one with a run of spaces or a leading or trailing space, which a
/// re-parser would collapse (RFC 5322 3.2.2) or drop.
func formatMailbox(name: String?, address: String, for target: MailboxFormatTarget) -> String {
    guard let name, !name.isEmpty else { return address }
    return "\(formatDisplayName(name, for: target)) <\(address)>"
}

private func formatDisplayName(_ name: String, for target: MailboxFormatTarget) -> String {
    if target == .rfc822Header && !name.unicodeScalars.allSatisfy(\.isASCII) {
        return EncodedWord.encode(name)
    }
    let spacesSurviveUnquoted = !name.hasPrefix(" ") && !name.hasSuffix(" ") && !name.contains("  ")
    guard !spacesSurviveUnquoted || name.unicodeScalars.contains(where: displayNameScalarNeedsQuoting) else {
        return name
    }
    let escaped = name
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private let rfc5322AtextSymbols = Set("!#$%&'*+-/=?^_`{|}~".unicodeScalars)

private func displayNameScalarNeedsQuoting(_ scalar: Unicode.Scalar) -> Bool {
    guard scalar.isASCII else { return false }
    if scalar == " " { return false }
    if CharacterSet.alphanumerics.contains(scalar) { return false }
    return !rfc5322AtextSymbols.contains(scalar)
}

public enum AddressParser {
    /// RFC 5322 groups contribute their members and drop the group name, so
    /// `undisclosed-recipients:;` yields nothing.
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
        var domainLiteralDepth = 0
        var inGroup = false
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
                if ch == "[" { domainLiteralDepth += 1; current.append(ch); continue }
                if ch == "]" { domainLiteralDepth = max(0, domainLiteralDepth - 1); current.append(ch); continue }
                if ch == "," && angle == 0 {
                    out.append(current)
                    current = ""
                    continue
                }
                let outsideAddressDelimiters = angle == 0 && domainLiteralDepth == 0
                if ch == ":" && outsideAddressDelimiters && !inGroup {
                    // `current` holds the group's display name, which is not a recipient.
                    inGroup = true
                    current = ""
                    continue
                }
                if ch == ";" && outsideAddressDelimiters && inGroup {
                    inGroup = false
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

        var noComments = ""
        var inQuotes = false
        var quotedPairPending = false
        var paren = 0
        for ch in trimmed {
            if !inQuotes {
                if paren > 0 {
                    // Inside a comment only nesting and quoted-pairs such as
                    // `\)` matter (RFC 5322 3.2.2); a `"` there is plain text.
                    if quotedPairPending {
                        quotedPairPending = false
                    } else if ch == "\\" {
                        quotedPairPending = true
                    } else if ch == "(" {
                        paren += 1
                    } else if ch == ")" {
                        paren -= 1
                    }
                    continue
                }
                if ch == "\"" { inQuotes = true; noComments.append(ch); continue }
                if ch == "(" { paren += 1; continue }
                if ch == ")" { continue }
                noComments.append(ch)
                continue
            }
            if quotedPairPending {
                quotedPairPending = false
            } else if ch == "\\" {
                quotedPairPending = true
            } else if ch == "\"" {
                inQuotes = false
            }
            noComments.append(ch)
        }

        let s = noComments.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }

        if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
            let addr = normalizeObsoleteAddrSpec(String(s[s.index(after: lt)..<gt]))
            if !addr.isEmpty {
                let phrase = String(s[..<lt]).trimmingCharacters(in: .whitespaces)
                let decoded = EncodedWord.decode(unquotePhrase(phrase))
                return ParsedAddress(displayName: decoded.isEmpty ? nil : decoded, address: addr)
            }
            // An empty `<>` (as in `<a@x> <>`): never emit an empty address.
            let stripped = s
                .replacingOccurrences(of: "<", with: "")
                .replacingOccurrences(of: ">", with: "")
                .trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { return nil }
            return ParsedAddress(displayName: nil, address: stripped)
        }
        return ParsedAddress(displayName: nil, address: normalizeObsoleteAddrSpec(s))
    }

    /// RFC 5322 4.4 obsolete forms: `@node.test:jdoe@test  . example` ->
    /// `jdoe@test.example`. Quoted local-parts and domain literals are kept.
    private static func normalizeObsoleteAddrSpec(_ spec: String) -> String {
        var remaining = Substring(spec.trimmingCharacters(in: .whitespaces))
        if remaining.first == "@", let routeEnd = remaining.firstIndex(of: ":") {
            remaining = remaining[remaining.index(after: routeEnd)...]
        }
        var out = ""
        var pendingWhitespace = ""
        var inQuotes = false
        var inDomainLiteral = false
        var quotedPairPending = false
        for ch in remaining {
            if inQuotes || inDomainLiteral {
                out.append(ch)
                if quotedPairPending {
                    quotedPairPending = false
                } else if ch == "\\" {
                    quotedPairPending = true
                } else if inQuotes && ch == "\"" {
                    inQuotes = false
                } else if inDomainLiteral && ch == "]" {
                    inDomainLiteral = false
                }
                continue
            }
            if ch == " " || ch == "\t" {
                pendingWhitespace.append(ch)
                continue
            }
            let touchesSeparator = ch == "." || ch == "@" || out.last == "." || out.last == "@"
            if !touchesSeparator {
                out += pendingWhitespace
            }
            pendingWhitespace = ""
            if ch == "\"" { inQuotes = true }
            if ch == "[" { inDomainLiteral = true }
            out.append(ch)
        }
        return out
    }

    /// `"Doe, John" Jr` -> `Doe, John Jr`; `"Smith \"Bob\""` -> `Smith "Bob"`.
    /// Unquoted whitespace runs read as one space (RFC 5322 3.2.2); quoted
    /// whitespace is kept as written.
    private static func unquotePhrase(_ phrase: String) -> String {
        var out = ""
        var inQuotes = false
        var quotedPairPending = false
        var previousWasUnquotedWhitespace = false
        for ch in phrase {
            let isUnquotedWhitespace = !inQuotes && !quotedPairPending && (ch == " " || ch == "\t")
            defer { previousWasUnquotedWhitespace = isUnquotedWhitespace }
            if isUnquotedWhitespace {
                if !previousWasUnquotedWhitespace { out.append(" ") }
                continue
            }
            if quotedPairPending {
                out.append(ch)
                quotedPairPending = false
                continue
            }
            if ch == "\"" {
                inQuotes.toggle()
                continue
            }
            if inQuotes && ch == "\\" {
                quotedPairPending = true
                continue
            }
            out.append(ch)
        }
        return out
    }
}
