import Foundation

extension UInt8 {
    /// Decode a single ASCII hex digit (0-9, A-F, a-f) to its 0-15 value, or
    /// nil if the byte is not a hex digit. Shared by the quoted-printable
    /// (MIMEParser) and RFC 2047 Q-encoding (EncodedWord) decoders.
    var hexNibble: Int? {
        switch self {
        case 0x30...0x39: return Int(self - 0x30)
        case 0x41...0x46: return Int(self - 0x41 + 10)
        case 0x61...0x66: return Int(self - 0x61 + 10)
        default: return nil
        }
    }
}

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
                let hi = chars[i + 1].hexNibble
                let lo = chars[i + 2].hexNibble
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

    public static func decodeBytes(_ bytes: Data, charset: String) -> String? {
        let cs = charset.lowercased()
        switch cs {
        case "utf-8", "utf8", "us-ascii", "ascii":
            // Strict UTF-8 decode returns nil on ANY invalid byte, and callers
            // coalesce nil to "" -- which silently drops the whole subject/body
            // for a mislabeled sender with a stray high byte. Fall back to a
            // lossy decode (substitutes U+FFFD) so we never return nil here.
            if let s = String(data: bytes, encoding: .utf8) { return s }
            return String(decoding: bytes, as: UTF8.self)
        case "iso-8859-1", "latin-1", "latin1":
            return String(data: bytes, encoding: .isoLatin1)
        case "windows-1252", "cp1252":
            // Windows-1252 differs from ISO-8859-1 in 0x80-0x9F: cp1252 places
            // curly quotes, em-dash, euro sign, etc. there, where Latin-1 has
            // C1 control chars. Decode with the correct table.
            return String(data: bytes, encoding: .windowsCP1252)
        default:
            // Try CFString lookup as a last resort.
            let encoding = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
            if encoding != kCFStringEncodingInvalidId {
                let nsEnc = CFStringConvertEncodingToNSStringEncoding(encoding)
                return String(data: bytes, encoding: String.Encoding(rawValue: nsEnc))
            }
            // Same non-nil-preserving fallback as the utf-8 case: never drop the
            // whole value on an unknown or undecodable charset.
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
