import Foundation

public struct RawMessage {
    public var headers: [(String, String)] = []
    public var body: Data = Data()

    public init() {}

    public func value(for name: String) -> String? {
        let lower = name.lowercased()
        for (k, v) in headers where k.lowercased() == lower {
            return v
        }
        return nil
    }

    public func values(for name: String) -> [String] {
        let lower = name.lowercased()
        return headers.compactMap { $0.0.lowercased() == lower ? $0.1 : nil }
    }
}

public enum RFC822Parser {
    /// Split the raw input into a headers section (decoded as UTF-8, replacing
    /// invalid bytes) and a body (raw bytes).
    public static func parse(_ data: Data) throws -> RawMessage {
        let (headerData, bodyData) = splitHeadersAndBody(data)
        let headerStr = decode(headerData)
        let lines = unfold(headerStr)
        var msg = RawMessage()
        msg.body = bodyData
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                msg.headers.append((name, value))
            }
        }
        return msg
    }

    private static func splitHeadersAndBody(_ data: Data) -> (Data, Data) {
        // Search for the first blank line. Accept LF/LF, CR/LF/CR/LF, mixed.
        // This materializes the whole message into a [UInt8] rather than
        // scanning Data subranges. That copy is intentional-for-simplicity: the
        // binary processes one short-lived message per invocation, so the extra
        // allocation is negligible, and index-based [UInt8] scanning keeps the
        // CRLF-boundary logic (which is fragile -- see the crlf_separator test)
        // easy to read. Not worth a Data-subrange rewrite.
        let bytes = [UInt8](data)
        // A MIME body part with no header fields starts with the blank line
        // (RFC 2046 5.1.1).
        if bytes.first == 0x0A {
            return (Data(), Data(bytes.dropFirst()))
        }
        if bytes.starts(with: [0x0D, 0x0A]) {
            return (Data(), Data(bytes.dropFirst(2)))
        }
        var i = 0
        while i < bytes.count {
            // case 1: LF LF
            if bytes[i] == 0x0A {
                if i + 1 < bytes.count && bytes[i + 1] == 0x0A {
                    let header = Data(bytes[0..<i])
                    let body = Data(bytes[(i + 2)...])
                    return (header, body)
                }
                // case 2: LF CR LF
                if i + 2 < bytes.count && bytes[i + 1] == 0x0D && bytes[i + 2] == 0x0A {
                    let header = Data(bytes[0..<i])
                    let body = Data(bytes[(i + 3)...])
                    return (header, body)
                }
            }
            // case 3: CRLF CRLF
            if bytes[i] == 0x0D && i + 3 < bytes.count
                && bytes[i + 1] == 0x0A && bytes[i + 2] == 0x0D && bytes[i + 3] == 0x0A {
                let header = Data(bytes[0..<i])
                let body = Data(bytes[(i + 4)...])
                return (header, body)
            }
            i += 1
        }
        // No blank line found: treat the whole input as headers (body empty).
        return (data, Data())
    }

    private static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    /// Unfold RFC 5322 headers: a line beginning with WSP is a continuation of
    /// the previous logical line, joined by dropping only the line break (the
    /// WSP stays, RFC 5322 2.2.3). Empty lines are skipped.
    private static func unfold(_ s: String) -> [String] {
        // Normalize line endings so the grapheme cluster "\r\n" doesn't hide LF
        // from the splitter (in Swift, "\r\n" is a single Character).
        let normalized = s.replacingOccurrences(of: "\r\n", with: "\n")
        var lines: [String] = []
        for raw in normalized.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }) {
            let stripped = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            if stripped.isEmpty { continue }
            if let first = stripped.first, first == " " || first == "\t" {
                if !lines.isEmpty {
                    lines[lines.count - 1] += stripped
                }
                continue
            }
            lines.append(stripped)
        }
        return lines
    }

    /// Parse a header value of the form `value; param1=foo; param2="bar"` into
    /// (mainValue, params). Params are returned with lowercased keys; values are
    /// unquoted.
    public static func parseStructured(_ value: String) -> (main: String, params: [String: String]) {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escape = false
        for ch in value {
            if escape {
                current.append(ch)
                escape = false
                continue
            }
            if ch == "\\" && inQuotes {
                escape = true
                continue
            }
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
                continue
            }
            if ch == ";" && !inQuotes {
                parts.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { parts.append(current) }

        let main = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        var params: [String: String] = [:]
        for p in parts.dropFirst() {
            let trimmed = p.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            params[key] = val
        }
        return (main, params)
    }
}
