import Foundation

/// Build the final .eml byte stream for the edit-draft path: start from the
/// raw rfc822 headers + body, apply CLI-driven header overrides (To/Cc/Bcc
/// finalized from positional + `-t` logic; From set from `-f`/`-F`), then
/// concatenate.
///
/// Body bytes are passed through verbatim -- no MIME re-encoding. The .eml
/// produced here is what `open -a Mail` opens, which Mail's WKWebView then
/// renders.
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

    /// Replace To/Cc/Bcc with the CLI-finalized values from `finalRecipients`
    /// (whose lists already reflect the positional / `-t` rules from
    /// `main.swift`). Set or replace From if `options.fromAddress` is set.
    /// All other headers pass through in original order.
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
        // Bcc is serialized as a plain rfc822 header. Verified empirically
        // (2026-07-08): Mail's "Send Again" consumes it as an envelope
        // recipient and strips the Bcc header from every transmitted copy
        // -- including the Bcc recipient's own -- so it stays blind, the same
        // guarantee as the classic path's dedicated bcc-recipient objects.
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

    /// Strip embedded CR and LF from a header key or value so a crafted display
    /// name or address (e.g. `"Alice\r\nBcc: evil@x"`) cannot break out of the
    /// header line and inject arbitrary headers. Both bare `\r`, bare `\n`, and
    /// `\r\n` folds are collapsed to a single space; this is the choke point
    /// through which every serialized header value passes.
    static func sanitizeHeaderValue(_ s: String) -> String {
        // NB: check at the unicode-scalar level. Swift fuses "\r\n" into a
        // single Character grapheme cluster, so `s.contains("\r")` is FALSE for
        // a value containing a CRLF -- iterate scalars instead.
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

    /// Keep a header line within RFC 5322's 998-octet limit (2.1.1) by
    /// inserting a CRLF before a space, which unfolding removes again. The
    /// parser unfolds each header onto one line, so a long References or a
    /// long To list would otherwise be written past the limit. A run with no
    /// space to break at stays long.
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
