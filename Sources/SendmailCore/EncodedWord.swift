import Foundation

extension UInt8 {
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

    /// 45 bytes per word keeps it under RFC 2047's 75-character limit; words
    /// split only between scalars, so each decodes to whole characters.
    public static func encode(_ input: String) -> String {
        let maxBytesPerWord = 45
        var chunks: [Data] = []
        var current = Data()
        for scalar in input.unicodeScalars {
            let scalarBytes = Data(String(scalar).utf8)
            if current.count + scalarBytes.count > maxBytesPerWord {
                chunks.append(current)
                current = Data()
            }
            current.append(scalarBytes)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
            .map { "=?UTF-8?B?\($0.base64EncodedString())?=" }
            .joined(separator: " ")
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
            if b == 0x5F {
                out.append(0x20)
                i += 1
                continue
            }
            if b == 0x3D && i + 2 < chars.count {
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
            // Never nil: callers coalesce nil to "", which would drop a whole
            // subject or body over one stray high byte.
            if let s = String(data: bytes, encoding: .utf8) { return s }
            return String(decoding: bytes, as: UTF8.self)
        case "iso-8859-1", "latin-1", "latin1":
            return String(data: bytes, encoding: .isoLatin1)
        case "windows-1252", "cp1252":
            // Not Latin-1: cp1252 has printable characters in 0x80-0x9F.
            return String(data: bytes, encoding: .windowsCP1252)
        default:
            let encoding = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
            if encoding != kCFStringEncodingInvalidId {
                let nsEnc = CFStringConvertEncodingToNSStringEncoding(encoding)
                return String(data: bytes, encoding: String.Encoding(rawValue: nsEnc))
            }
            // Never nil, as above.
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
