import Foundation

public enum MIMEParser {
    /// Build a ParsedMessage from a raw RFC 822 message.
    public static func parse(_ raw: RawMessage) -> ParsedMessage {
        var msg = ParsedMessage()
        msg.subject = EncodedWord.decode(raw.value(for: "Subject") ?? "")
        msg.to = raw.values(for: "To").flatMap { AddressParser.parse($0) }
        msg.cc = raw.values(for: "Cc").flatMap { AddressParser.parse($0) }
        msg.bcc = raw.values(for: "Bcc").flatMap { AddressParser.parse($0) }

        let ctRaw = raw.value(for: "Content-Type") ?? "text/plain; charset=utf-8"
        let (mainType, params) = RFC822Parser.parseStructured(ctRaw)
        let mt = mainType.lowercased()

        if mt.hasPrefix("multipart/") {
            walkMultipart(body: raw.body, params: params, into: &msg, depth: 0)
            if msg.body.isEmpty {
                // No text part found in the multipart — leave body empty rather than dumping raw bytes.
                msg.body = ""
            }
        } else {
            let cte = (raw.value(for: "Content-Transfer-Encoding") ?? "").lowercased()
            let decoded = decodeTransfer(raw.body, encoding: cte)
            let charset = params["charset"] ?? "utf-8"
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

    private static func walkMultipart(body: Data, params: [String: String], into msg: inout ParsedMessage, depth: Int) {
        guard let boundary = params["boundary"], !boundary.isEmpty else { return }
        if depth > 4 { return }

        for part in splitParts(body, boundary: boundary) {
            guard let sub = try? RFC822Parser.parse(part) else { continue }
            let ctRaw = sub.value(for: "Content-Type") ?? "text/plain"
            let (mainType, subParams) = RFC822Parser.parseStructured(ctRaw)
            let mt = mainType.lowercased()
            let disposition = (sub.value(for: "Content-Disposition") ?? "").lowercased()
            let (dispMain, dispParams) = RFC822Parser.parseStructured(disposition)

            if mt.hasPrefix("multipart/") {
                walkMultipart(body: sub.body, params: subParams, into: &msg, depth: depth + 1)
                continue
            }

            let cte = (sub.value(for: "Content-Transfer-Encoding") ?? "").lowercased()
            let decoded = decodeTransfer(sub.body, encoding: cte)

            let isAttachment = dispMain == "attachment"
                || dispParams["filename"] != nil
                || subParams["name"] != nil
                || (mt.hasPrefix("text/") == false && mt != "")

            // Treat text/* without an explicit attachment disposition as a body candidate.
            if !isAttachment && mt.hasPrefix("text/") {
                let charset = subParams["charset"] ?? "utf-8"
                let text = EncodedWord.decodeBytes(decoded, charset: charset) ?? ""

                // Capture raw HTML for the rich-HTML render path independent of
                // whether plain-text already won the body slot.
                if mt == "text/html" && msg.htmlBody == nil {
                    msg.htmlBody = text
                }

                if msg.body.isEmpty {
                    msg.body = (mt == "text/html") ? stripHTML(text) : text
                }
                continue
            }

            // Skip inline body parts (e.g. multipart/related images referenced
            // by CID from the HTML): Content-Disposition: inline with no
            // filename/name param. These ride along in the raw .eml and are not
            // user-facing attachments. Genuine attachments -- disposition
            // "attachment", a filename/name param present, or a bare non-text
            // part with no disposition at all -- still fall through below.
            let hasName = dispParams["filename"] != nil || subParams["name"] != nil
            if dispMain == "inline" && !hasName {
                continue
            }

            let nameRaw = dispParams["filename"]
                ?? subParams["name"]
                ?? "attachment-\(msg.attachments.count + 1).bin"
            let filename = EncodedWord.decode(nameRaw)
            msg.attachments.append(Attachment(filename: filename, contentType: mt, data: decoded))
        }
    }

    /// Split a multipart body on its boundary into the inner parts. Per RFC 2046,
    /// boundary delimiters appear as `--boundary` on a line by themselves; the
    /// final delimiter is `--boundary--`.
    private static func splitParts(_ body: Data, boundary: String) -> [Data] {
        let delim = Data("--\(boundary)".utf8)
        let bytes = [UInt8](body)
        let dbytes = [UInt8](delim)
        var positions: [Int] = []
        var i = 0
        while i <= bytes.count - dbytes.count {
            if matchAt(bytes, at: i, pattern: dbytes) {
                // Must be at line start (i == 0, or preceded by \n).
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
            // Check for terminating "--".
            if start + 1 < bytes.count && bytes[start] == 0x2D && bytes[start + 1] == 0x2D {
                break
            }
            // Skip CRLF / LF after the delimiter.
            var s = start
            while s < bytes.count, bytes[s] == 0x0D || bytes[s] == 0x0A {
                s += 1
                if s < bytes.count && bytes[s - 1] == 0x0D && bytes[s] == 0x0A { s += 1; break }
                if bytes[s - 1] == 0x0A { break }
            }
            let end = (k + 1 < positions.count) ? positions[k + 1] : bytes.count
            // Trim trailing CRLF before the next delimiter.
            var e = end
            while e > s && (bytes[e - 1] == 0x0A || bytes[e - 1] == 0x0D) {
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

    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        var out = Data()
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D { // '='
                if i + 1 < bytes.count && bytes[i + 1] == 0x0A {
                    i += 2; continue // soft break "=\n"
                }
                if i + 2 < bytes.count && bytes[i + 1] == 0x0D && bytes[i + 2] == 0x0A {
                    i += 3; continue // soft break "=\r\n"
                }
                if i + 2 < bytes.count {
                    let hi = bytes[i + 1].hexNibble
                    let lo = bytes[i + 2].hexNibble
                    if let hi = hi, let lo = lo {
                        out.append(UInt8(hi * 16 + lo))
                        i += 3
                        continue
                    }
                }
            }
            out.append(b)
            i += 1
        }
        return out
    }

    /// Tag-strip an HTML body for a tolerable plain-text fallback.
    /// Drops <style>, <script>, and <head> block contents (not just their
    /// tags), turns block-level closing tags into newlines, strips the
    /// remaining tags, and collapses whitespace.
    private static func stripHTML(_ html: String) -> String {
        var s = html

        let dropBlocks = [
            #"<style\b[^>]*>[\s\S]*?</style>"#,
            #"<script\b[^>]*>[\s\S]*?</script>"#,
            #"<head\b[^>]*>[\s\S]*?</head>"#,
            #"<!--[\s\S]*?-->"#,
        ]
        for pattern in dropBlocks {
            s = replaceRegex(in: s, pattern: pattern, with: "")
        }

        let toNewline = [
            #"<br\s*/?>"#,
            #"</p\s*>"#,
            #"</div\s*>"#,
            #"</h[1-6]\s*>"#,
            #"</li\s*>"#,
            #"</tr\s*>"#,
        ]
        for pattern in toNewline {
            s = replaceRegex(in: s, pattern: pattern, with: "\n")
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

    /// Decode HTML character references in a single left-to-right pass so that
    /// an already-escaped ampersand does not get its expansion re-scanned. For
    /// example `&amp;lt;` must decode to the literal `&lt;`, not `<` -- the old
    /// chained-replace approach turned `&amp;` into `&` first and then the
    /// resulting `&lt;` into `<`. Handles named entities plus decimal `&#DDD;`
    /// and hex `&#xHH;` numeric references.
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
        // Rebuild the string in one pass, copying the gaps between matches
        // verbatim so a decoded value can never be re-scanned as an entity.
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
                // Unknown named entity: leave it untouched.
                out += ns.substring(with: full)
            }
            cursor = full.location + full.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    private static func replaceRegex(in s: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return s
        }
        let ns = s as NSString
        return re.stringByReplacingMatches(
            in: s,
            options: [],
            range: NSRange(location: 0, length: ns.length),
            withTemplate: template
        )
    }
}
