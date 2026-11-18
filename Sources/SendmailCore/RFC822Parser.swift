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
        // The CRLF-boundary logic is fragile; see the crlf_separator test.
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
            if bytes[i] == 0x0A {
                if i + 1 < bytes.count && bytes[i + 1] == 0x0A {
                    let header = Data(bytes[0..<i])
                    let body = Data(bytes[(i + 2)...])
                    return (header, body)
                }
                if i + 2 < bytes.count && bytes[i + 1] == 0x0D && bytes[i + 2] == 0x0A {
                    let header = Data(bytes[0..<i])
                    let body = Data(bytes[(i + 3)...])
                    return (header, body)
                }
            }
            if bytes[i] == 0x0D && i + 3 < bytes.count
                && bytes[i + 1] == 0x0A && bytes[i + 2] == 0x0D && bytes[i + 3] == 0x0A {
                let header = Data(bytes[0..<i])
                let body = Data(bytes[(i + 4)...])
                return (header, body)
            }
            i += 1
        }
        return (data, Data())
    }

    private static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    /// Unfolding drops only the line break; the continuation's WSP stays
    /// (RFC 5322 2.2.3).
    private static func unfold(_ s: String) -> [String] {
        // Swift fuses "\r\n" into one Character, which a split on "\n" never
        // matches; without this, adjacent headers merge into one.
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

    /// Param keys come back lowercased and values unquoted.
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
