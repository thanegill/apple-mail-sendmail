import Foundation

public struct ParsedAddress {
    public var displayName: String?
    public var address: String

    public init(displayName: String?, address: String) {
        self.displayName = displayName
        self.address = address
    }
}

/// Where a formatted mailbox string ends up. The two destinations differ only
/// in how a non-ASCII display name is written.
enum MailboxFormatTarget {
    /// A header line in the .eml that Mail opens. Non-ASCII display names are
    /// RFC 2047 encoded so the file stays plain RFC 5322.
    case rfc822Header
    /// Mail's `sender` property of an outgoing message. Mail encodes headers
    /// itself on send, so non-ASCII stays literal; pre-encoding it would risk
    /// Mail treating the encoded-word as literal text.
    case mailSender
}

/// Format a mailbox as either `Name <addr>` (when `name` is non-nil and
/// non-empty) or bare `addr`. This is the single source of truth for the
/// rule; it is shared by the plain path's `sender` property, the .eml
/// `From` header override, and the .eml To/Cc/Bcc serialization so all three
/// stay in lockstep.
///
/// A display name containing anything outside RFC 5322 `atext` and space
/// (e.g. the comma in `Doe, John`) is written as a quoted-string; unquoted,
/// a re-parser would split it into several mailboxes. So is one with a run
/// of spaces or a leading or trailing space, which a re-parser would
/// otherwise read as single spaces (RFC 5322 3.2.2) or drop.
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
    /// Split a header value like `"Alice" <a@x>, b@y (Bob), Carol <c@z>` into
    /// individual addresses, then parse each. Comments in parentheses are
    /// stripped; quoted-string display names are honored. RFC 5322 groups
    /// (`Team: a@x, b@y;`) contribute their member mailboxes and the group
    /// name is dropped, so `undisclosed-recipients:;` yields nothing.
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

        // Strip comments in parentheses (not nested in quotes).
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
            // Empty angle-bracket pair (e.g. the trailing `<>` in `<a@x> <>`).
            // Fall back to the token with angle brackets removed as the
            // address; never emit a ParsedAddress with an empty address.
            let stripped = s
                .replacingOccurrences(of: "<", with: "")
                .replacingOccurrences(of: ">", with: "")
                .trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { return nil }
            return ParsedAddress(displayName: nil, address: stripped)
        }
        return ParsedAddress(displayName: nil, address: normalizeObsoleteAddrSpec(s))
    }

    /// Rewrite the obsolete addr-spec forms of RFC 5322 4.4 to the current
    /// syntax: drop an obs-route (`@node.test:` before the address) and the
    /// whitespace (comments are already gone) around the dots and the `@` of
    /// an obs-local-part or obs-domain, so `jdoe@test  . example` becomes
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

    /// Decode an RFC 5322 display-name phrase: drop the delimiters of every
    /// quoted-string segment and unescape the quoted-pairs inside them, so
    /// `"Doe, John" Jr` becomes `Doe, John Jr` and `"Smith \"Bob\""` becomes
    /// `Smith "Bob"`. A run of whitespace between unquoted words (left by
    /// folding or a removed comment) reads as one space (RFC 5322 3.2.2);
    /// whitespace inside a quoted-string is kept as written.
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
