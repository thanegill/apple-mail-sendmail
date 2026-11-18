import Foundation

public enum MIMEParser {
    public static func parse(_ raw: RawMessage) -> ParsedMessage {
        var msg = ParsedMessage()
        msg.subject = EncodedWord.decode(raw.value(for: "Subject") ?? "")
        msg.from = raw.value(for: "From").flatMap { AddressParser.parse($0).first }
        msg.to = raw.values(for: "To").flatMap { AddressParser.parse($0) }
        msg.cc = raw.values(for: "Cc").flatMap { AddressParser.parse($0) }
        msg.bcc = raw.values(for: "Bcc").flatMap { AddressParser.parse($0) }

        let ctRaw = raw.value(for: "Content-Type") ?? "text/plain; charset=utf-8"
        let (mainType, params) = RFC822Parser.parseStructured(ctRaw)
        let mt = mainType.lowercased()

        if mt.hasPrefix("multipart/") {
            walkMultipart(body: raw.body, type: mt, params: params, into: &msg, depth: 0)
            if msg.body.isEmpty {
                msg.body = ""
            }
        } else {
            let cte = (raw.value(for: "Content-Transfer-Encoding") ?? "").lowercased()
            let decoded = decodeTransfer(raw.body, encoding: cte)
            let charset = parameterValue(params, named: "charset") ?? "utf-8"
            let text = EncodedWord.decodeBytes(decoded, charset: charset) ?? ""
            if mt == "text/html" {
                msg.htmlBody = text
                msg.body = stripHTML(text)
            } else {
                msg.body = text
            }
        }
        return msg
    }

    private static func walkMultipart(
        body: Data,
        type multipartType: String,
        params: [String: String],
        into msg: inout ParsedMessage,
        depth: Int
    ) {
        guard let boundary = parameterValue(params, named: "boundary"), !boundary.isEmpty else { return }
        if depth > 4 { return }
        // RFC 2046 5.1.5: a digest's parts default to message/rfc822.
        let defaultPartType = multipartType == "multipart/digest" ? "message/rfc822" : "text/plain"

        for part in splitParts(body, boundary: boundary) {
            guard let sub = try? RFC822Parser.parse(part) else { continue }
            let ctRaw = sub.value(for: "Content-Type") ?? defaultPartType
            let (mainType, subParams) = RFC822Parser.parseStructured(ctRaw)
            let mt = mainType.lowercased()
            // Lowercase only the disposition type: the filename parameter value
            // must keep its case (and any encoded-word payload with it).
            let (dispType, dispParams) = RFC822Parser.parseStructured(sub.value(for: "Content-Disposition") ?? "")
            let dispMain = dispType.lowercased()

            if mt.hasPrefix("multipart/") {
                walkMultipart(body: sub.body, type: mt, params: subParams, into: &msg, depth: depth + 1)
                continue
            }

            let cte = (sub.value(for: "Content-Transfer-Encoding") ?? "").lowercased()
            let decoded = decodeTransfer(sub.body, encoding: cte)

            let partName = parameterValue(dispParams, named: "filename", plainDecoding: EncodedWord.decode)
                ?? parameterValue(subParams, named: "name", plainDecoding: EncodedWord.decode)
            let isAttachment = dispMain == "attachment"
                || partName != nil
                || (mt.hasPrefix("text/") == false && mt != "")

            if !isAttachment && mt.hasPrefix("text/") {
                let charset = parameterValue(subParams, named: "charset") ?? "utf-8"
                let text = EncodedWord.decodeBytes(decoded, charset: charset) ?? ""

                if mt == "text/html" && msg.htmlBody == nil {
                    msg.htmlBody = text
                }

                // A whitespace-only part (an empty text/plain alternative)
                // leaves the slot to a later part.
                if msg.body.isEmpty && !text.allSatisfy(\.isWhitespace) {
                    msg.body = (mt == "text/html") ? stripHTML(text) : text
                }
                continue
            }

            // Inline parts with no name (e.g. CID images of multipart/related)
            // ride along in the raw .eml and are not user-facing attachments.
            if dispMain == "inline" && partName == nil {
                continue
            }

            let filename = partName ?? "attachment-\(msg.attachments.count + 1).bin"
            msg.attachments.append(Attachment(filename: filename, contentType: mt, data: decoded))
        }
    }

    /// An RFC 2231 extended form wins over the plain `name=` that senders
    /// include as a legacy fallback. Filenames pass `plainDecoding` (RFC 2047),
    /// since senders put encoded-words in them; a boundary must stay verbatim.
    private static func parameterValue(
        _ params: [String: String],
        named name: String,
        plainDecoding: (String) -> String = { $0 }
    ) -> String? {
        if let extended = params["\(name)*"] {
            return decodeExtendedValue([(text: extended, isEncoded: true)], plainDecoding: plainDecoding)
        }

        var segments: [(text: String, isEncoded: Bool)] = []
        while true {
            let index = segments.count
            if let encoded = params["\(name)*\(index)*"] {
                segments.append((encoded, true))
            } else if let plain = params["\(name)*\(index)"] {
                segments.append((plain, false))
            } else {
                break
            }
        }
        if !segments.isEmpty {
            return decodeExtendedValue(segments, plainDecoding: plainDecoding)
        }

        return params[name].map(plainDecoding)
    }

    /// All-literal continuations get `plainDecoding`, since some senders
    /// split an encoded-word across them.
    private static func decodeExtendedValue(
        _ segments: [(text: String, isEncoded: Bool)],
        plainDecoding: (String) -> String
    ) -> String {
        guard segments.contains(where: \.isEncoded) else {
            return plainDecoding(segments.map(\.text).joined())
        }
        var charset = "utf-8"
        var bytes = Data()
        for (index, segment) in segments.enumerated() {
            var text = Substring(segment.text)
            if index == 0 && segment.isEncoded {
                let pieces = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if pieces.count == 3 {
                    if !pieces[0].isEmpty { charset = String(pieces[0]) }
                    text = pieces[2]
                }
            }
            bytes.append(segment.isEncoded ? percentDecode(text) : Data(text.utf8))
        }
        return EncodedWord.decodeBytes(bytes, charset: charset) ?? String(decoding: bytes, as: UTF8.self)
    }

    private static func percentDecode(_ text: Substring) -> Data {
        let bytes = [UInt8](text.utf8)
        var out = Data()
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25, i + 2 < bytes.count,
               let hi = bytes[i + 1].hexNibble, let lo = bytes[i + 2].hexNibble {
                out.append(UInt8(hi * 16 + lo))
                i += 3
                continue
            }
            out.append(bytes[i])
            i += 1
        }
        return out
    }

    private static func splitParts(_ body: Data, boundary: String) -> [Data] {
        let delim = Data("--\(boundary)".utf8)
        let bytes = [UInt8](body)
        let dbytes = [UInt8](delim)
        var positions: [Int] = []
        var i = 0
        while i <= bytes.count - dbytes.count {
            if matchAt(bytes, at: i, pattern: dbytes) {
                if i == 0 || bytes[i - 1] == 0x0A || bytes[i - 1] == 0x0D {
                    positions.append(i)
                    i += dbytes.count
                    continue
                }
            }
            i += 1
        }
        var parts: [Data] = []
        for k in 0..<positions.count {
            let start = positions[k] + dbytes.count
            if start + 1 < bytes.count && bytes[start] == 0x2D && bytes[start + 1] == 0x2D {
                break
            }
            var s = start
            while s < bytes.count, bytes[s] == 0x0D || bytes[s] == 0x0A {
                s += 1
                if s < bytes.count && bytes[s - 1] == 0x0D && bytes[s] == 0x0A { s += 1; break }
                if bytes[s - 1] == 0x0A { break }
            }
            let nextDelimiter = (k + 1 < positions.count) ? positions[k + 1] : nil
            var e = nextDelimiter ?? bytes.count
            // Only the one line break right before a delimiter belongs to it
            // (RFC 2046 5.1.1); any earlier blank lines are part content.
            if nextDelimiter != nil && e > s && bytes[e - 1] == 0x0A {
                e -= 1
            }
            if nextDelimiter != nil && e > s && bytes[e - 1] == 0x0D {
                e -= 1
            }
            if s < e {
                parts.append(Data(bytes[s..<e]))
            }
        }
        return parts
    }

    private static func matchAt(_ bytes: [UInt8], at: Int, pattern: [UInt8]) -> Bool {
        if at + pattern.count > bytes.count { return false }
        for k in 0..<pattern.count {
            if bytes[at + k] != pattern[k] { return false }
        }
        return true
    }

    public static func decodeTransfer(_ data: Data, encoding: String) -> Data {
        switch encoding {
        case "base64":
            let stripped = data.filter { b in
                b != 0x0A && b != 0x0D && b != 0x20 && b != 0x09
            }
            if let decoded = Data(base64Encoded: stripped, options: [.ignoreUnknownCharacters]) {
                return decoded
            }
            return data
        case "quoted-printable":
            return decodeQuotedPrintable(data)
        default:
            return data
        }
    }

    /// Decode quoted-printable line by line (RFC 2045 6.7). Whitespace at the
    /// end of an encoded line is transport padding and is deleted (rule 3), so
    /// a line ending in `=` after that is a soft line break (rule 5) even when
    /// padding followed the `=`. Hard line breaks keep their CRLF or LF form.
    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        var out = Data()
        let lines = [UInt8](data).split(separator: 0x0A, omittingEmptySubsequences: false)
        for (lineIndex, rawLine) in lines.enumerated() {
            var line = rawLine[...]
            let endsWithCR = line.last == 0x0D
            if endsWithCR { line = line.dropLast() }
            while let last = line.last, last == 0x20 || last == 0x09 {
                line = line.dropLast()
            }
            let isSoftBreak = line.last == 0x3D
            if isSoftBreak { line = line.dropLast() }
            appendQuotedPrintableEscapes(line, to: &out)
            let isFinalLine = lineIndex == lines.count - 1
            if !isSoftBreak && !isFinalLine {
                if endsWithCR { out.append(0x0D) }
                out.append(0x0A)
            }
        }
        return out
    }

    private static func appendQuotedPrintableEscapes(_ line: ArraySlice<UInt8>, to out: inout Data) {
        var i = line.startIndex
        while i < line.endIndex {
            if line[i] == 0x3D, i + 2 < line.endIndex,
               let hi = line[i + 1].hexNibble, let lo = line[i + 2].hexNibble {
                out.append(UInt8(hi * 16 + lo))
                i += 3
                continue
            }
            out.append(line[i])
            i += 1
        }
    }

    private static let dropBlockRegexes: [NSRegularExpression] = compileRegexes([
        #"<style\b[^>]*>[\s\S]*?</style>"#,
        #"<script\b[^>]*>[\s\S]*?</script>"#,
        #"<head\b[^>]*>[\s\S]*?</head>"#,
        #"<!--[\s\S]*?-->"#,
    ])

    private static let toNewlineRegexes: [NSRegularExpression] = compileRegexes([
        #"<br\s*/?>"#,
        #"</p\s*>"#,
        #"</div\s*>"#,
        #"</h[1-6]\s*>"#,
        #"</li\s*>"#,
        #"</tr\s*>"#,
    ])

    private static func compileRegexes(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    private static func stripHTML(_ html: String) -> String {
        var s = html

        for re in dropBlockRegexes {
            s = replaceRegex(in: s, regex: re, with: "")
        }

        for re in toNewlineRegexes {
            s = replaceRegex(in: s, regex: re, with: "\n")
        }

        var out = ""
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { out.append(ch) }
        }

        let decoded = decodeEntities(out)

        var result: [String] = []
        var lastBlank = false
        for raw in decoded.split(separator: "\n", omittingEmptySubsequences: false) {
            let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if collapsed.isEmpty {
                if !lastBlank { result.append("") }
                lastBlank = true
            } else {
                result.append(collapsed)
                lastBlank = false
            }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One left-to-right pass, so `&amp;lt;` decodes to the literal `&lt;`:
    /// chained replaces would re-scan a decoded value as an entity.
    private static func decodeEntities(_ s: String) -> String {
        let named: [String: String] = [
            "amp": "&",
            "lt": "<",
            "gt": ">",
            "quot": "\"",
            "apos": "'",
            "nbsp": " ",
        ]
        let pattern = #"&(#\d+|#x[0-9a-fA-F]+|[a-zA-Z]+);"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else {
            return s
        }
        let ns = s as NSString
        let matches = re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
        var out = ""
        var cursor = 0
        for m in matches {
            let full = m.range
            if full.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            }
            let token = ns.substring(with: m.range(at: 1))
            if token.hasPrefix("#x") || token.hasPrefix("#X") {
                let hex = String(token.dropFirst(2))
                if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                    out.append(Character(scalar))
                } else {
                    out += ns.substring(with: full)
                }
            } else if token.hasPrefix("#") {
                let dec = String(token.dropFirst())
                if let code = UInt32(dec, radix: 10), let scalar = Unicode.Scalar(code) {
                    out.append(Character(scalar))
                } else {
                    out += ns.substring(with: full)
                }
            } else if let value = named[token.lowercased()] {
                out += value
            } else {
                out += ns.substring(with: full)
            }
            cursor = full.location + full.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    private static func replaceRegex(in s: String, regex re: NSRegularExpression, with template: String) -> String {
        let ns = s as NSString
        return re.stringByReplacingMatches(
            in: s,
            options: [],
            range: NSRange(location: 0, length: ns.length),
            withTemplate: template
        )
    }
}
