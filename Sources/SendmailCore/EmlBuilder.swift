import Foundation

/// Every CLI override must be applied here: the compose Send Again makes is
/// not in Mail's `outgoing messages`, so nothing can be changed after the open.
public enum EmlBuilder {
    public static func buildEml(
        raw: RawMessage,
        finalRecipients: ParsedMessage,
        options: Options
    ) -> Data {
        let headers = applyOverrides(
            headers: raw.headers,
            finalRecipients: finalRecipients,
            options: options
        )
        return serialize(headers: headers, body: raw.body)
    }

    static func applyOverrides(
        headers: [(String, String)],
        finalRecipients: ParsedMessage,
        options: Options
    ) -> [(String, String)] {
        var out = headers
        let strip: Set<String> = ["to", "cc", "bcc"]
        out.removeAll { strip.contains($0.0.lowercased()) }
        // No `undisclosed-recipients:;` placeholder for an empty To: Mail's compose
        // rejects group syntax as an invalid address and blocks the send.
        if !finalRecipients.to.isEmpty {
            out.append(("To", joinAddresses(finalRecipients.to)))
        }
        if !finalRecipients.cc.isEmpty {
            out.append(("Cc", joinAddresses(finalRecipients.cc)))
        }
        // Stays blind (verified 2026-07-08): Send Again delivers to Bcc as an
        // envelope recipient and strips the header from every copy, its own too.
        if !finalRecipients.bcc.isEmpty {
            out.append(("Bcc", joinAddresses(finalRecipients.bcc)))
        }
        if let addr = options.fromAddress {
            out.removeAll { $0.0.lowercased() == "from" }
            out.append(("From", formatMailbox(name: options.fromName, address: addr, for: .rfc822Header)))
        }
        return out
    }

    static func serialize(headers: [(String, String)], body: Data) -> Data {
        var out = Data()
        for (k, v) in headers {
            out.append(Data("\(fold("\(sanitizeHeaderValue(k)): \(sanitizeHeaderValue(v))"))\r\n".utf8))
        }
        out.append(Data("\r\n".utf8))
        out.append(body)
        return out
    }

    /// The choke point every serialized header passes through, so a crafted
    /// name like `"Alice\r\nBcc: evil@x"` cannot inject a header.
    static func sanitizeHeaderValue(_ s: String) -> String {
        // Scalars, not Characters: Swift fuses "\r\n" into one Character, so
        // `s.contains("\r")` is false for a value containing a CRLF.
        guard s.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) else {
            return s
        }
        var out = ""
        out.unicodeScalars.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            if scalar == "\r" || scalar == "\n" {
                out.unicodeScalars.append(" ")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// The parser unfolds each header onto one line, so a long References or
    /// To list must be folded again to stay within RFC 5322's 998-octet limit
    /// (2.1.1). A run with no space to break at stays long.
    static func fold(_ line: String) -> String {
        let maxLineOctets = 998
        guard line.utf8.count > maxLineOctets else { return line }
        var folded = ""
        var currentLineOctets = 0
        for (index, word) in line.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            let wordOctets = word.utf8.count
            if index == 0 {
                folded = String(word)
                currentLineOctets = wordOctets
            } else if !word.isEmpty && currentLineOctets + 1 + wordOctets > maxLineOctets {
                folded += "\r\n " + word
                currentLineOctets = 1 + wordOctets
            } else {
                folded += " " + word
                currentLineOctets += 1 + wordOctets
            }
        }
        return folded
    }

    private static func joinAddresses(_ addrs: [ParsedAddress]) -> String {
        addrs.map(formatAddress).joined(separator: ", ")
    }

    private static func formatAddress(_ a: ParsedAddress) -> String {
        formatMailbox(name: a.displayName, address: a.address, for: .rfc822Header)
    }
}
