import Foundation

/// Build the final .eml byte stream for the edit-draft path: start from the
/// raw rfc822 headers + body, apply CLI-driven header overrides (To/Cc/Bcc
/// finalized from positional + `-t` logic; From set from `-f`/`-F`), then
/// concatenate.
///
/// Body bytes are passed through verbatim — no MIME re-encoding. The .eml
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
        if !finalRecipients.to.isEmpty {
            out.append(("To", joinAddresses(finalRecipients.to)))
        }
        if !finalRecipients.cc.isEmpty {
            out.append(("Cc", joinAddresses(finalRecipients.cc)))
        }
        if !finalRecipients.bcc.isEmpty {
            out.append(("Bcc", joinAddresses(finalRecipients.bcc)))
        }
        if let addr = options.fromAddress {
            out.removeAll { $0.0.lowercased() == "from" }
            let value: String
            if let name = options.fromName, !name.isEmpty {
                value = "\(name) <\(addr)>"
            } else {
                value = addr
            }
            out.append(("From", value))
        }
        return out
    }

    static func serialize(headers: [(String, String)], body: Data) -> Data {
        var out = Data()
        for (k, v) in headers {
            out.append(Data("\(k): \(v)\r\n".utf8))
        }
        out.append(Data("\r\n".utf8))
        out.append(body)
        return out
    }

    private static func joinAddresses(_ addrs: [ParsedAddress]) -> String {
        addrs.map(formatAddress).joined(separator: ", ")
    }

    private static func formatAddress(_ a: ParsedAddress) -> String {
        guard let name = a.displayName, !name.isEmpty else { return a.address }
        return "\(name) <\(a.address)>"
    }
}
