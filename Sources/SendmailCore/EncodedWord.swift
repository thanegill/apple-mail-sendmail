import Foundation

public enum EncodedWord {
    /// Decode RFC 2047 encoded-words within a header value. Whitespace between
    /// adjacent encoded-words is dropped, as required by the spec.
    public static func decode(_ input: String) -> String {
        if !input.contains("=?") { return input }
        let pattern = #"=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return input
        }
        let ns = input as NSString
        let matches = regex.matches(in: input, options: [], range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return input }

        var out = ""
        var cursor = 0
        var previousWasEncoded = false
        for m in matches {
            let r = m.range
            var prefix = ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
            if previousWasEncoded && !prefix.isEmpty && prefix.trimmingCharacters(in: .whitespaces).isEmpty {
                // Per RFC 2047: drop whitespace between two adjacent encoded-words.
                prefix = ""
            }
            out += prefix

            let charset = ns.substring(with: m.range(at: 1))
            let encoding = ns.substring(with: m.range(at: 2)).uppercased()
            let payload = ns.substring(with: m.range(at: 3))
            if let decoded = decodeWord(charset: charset, encoding: encoding, payload: payload) {
                out += decoded
            } else {
                out += ns.substring(with: r)
            }

            cursor = r.location + r.length
            previousWasEncoded = true
        }
        out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        return out
    }

    private static func decodeWord(charset: String, encoding: String, payload: String) -> String? {
        let bytes: Data
        switch encoding {
        case "B":
            guard let d = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return nil }
            bytes = d
        case "Q":
            bytes = decodeQ(payload)
        default:
            return nil
        }
        return decodeBytes(bytes, charset: charset)
    }

    private static func decodeQ(_ s: String) -> Data {
        var out = Data()
        let chars = Array(s.utf8)
        var i = 0
        while i < chars.count {
            let b = chars[i]
            if b == 0x5F { // '_' → space
                out.append(0x20)
                i += 1
                continue
            }
            if b == 0x3D && i + 2 < chars.count { // '='
                let hi = hex(chars[i + 1])
                let lo = hex(chars[i + 2])
                if let hi = hi, let lo = lo {
                    out.append(UInt8(hi * 16 + lo))
                    i += 3
                    continue
                }
            }
            out.append(b)
            i += 1
        }
        return out
    }

    private static func hex(_ b: UInt8) -> Int? {
        switch b {
        case 0x30...0x39: return Int(b - 0x30)
        case 0x41...0x46: return Int(b - 0x41 + 10)
        case 0x61...0x66: return Int(b - 0x61 + 10)
        default: return nil
        }
    }

    public static func decodeBytes(_ bytes: Data, charset: String) -> String? {
        let cs = charset.lowercased()
        switch cs {
        case "utf-8", "utf8", "us-ascii", "ascii":
            return String(data: bytes, encoding: .utf8)
        case "iso-8859-1", "latin-1", "latin1", "windows-1252", "cp1252":
            return String(data: bytes, encoding: .isoLatin1)
        default:
            // Try CFString lookup as a last resort.
            let encoding = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
            if encoding != kCFStringEncodingInvalidId {
                let nsEnc = CFStringConvertEncodingToNSStringEncoding(encoding)
                return String(data: bytes, encoding: String.Encoding(rawValue: nsEnc))
            }
            return String(data: bytes, encoding: .utf8)
        }
    }
}
