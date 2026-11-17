import Foundation

public enum InfoRequest: Equatable {
    case help
    case version
}

public struct Options {
    /// Set when argv asks for help or version output instead of delivery;
    /// the caller prints it and exits 0 without reading stdin.
    public var infoRequest: InfoRequest? = nil
    public var readRecipientsFromHeaders: Bool = false
    public var fromAddress: String? = nil
    public var fromName: String? = nil
    public var send: Bool = false
    public var recipients: [String] = []

    public init() {}
}

public enum CLIError: Error {
    case usage(String)
}

public enum CLI {
    public static let versionText = "apple-mail-sendmail 0.1.0"

    // Legacy short flags whose value may be attached (-Bmime) OR the next argv
    // (-B 8BITMIME). When the value isn't attached, consume the following argv so
    // it isn't misparsed as a positional recipient. -v (verbose) and -n (no
    // aliasing) take no value and are deliberately absent here.
    private static let separateValueFlags: Set<Character> = ["O", "B", "N", "R", "X", "C"]

    public static func parse(_ argv: [String], env: [String: String]) throws -> Options {
        var opts = Options()
        if env["SENDMAIL_SEND"] == "1" {
            opts.send = true
        }

        var i = 0
        var endOfOptions = false
        while i < argv.count {
            let arg = argv[i]
            i += 1

            if endOfOptions {
                opts.recipients.append(arg)
                continue
            }

            if arg == "--" {
                endOfOptions = true
                continue
            }
            if arg == "-" {
                // stdin marker; some callers pass it. Treat as no-op.
                continue
            }
            if arg.hasPrefix("--") {
                switch arg {
                case "--send":
                    opts.send = true
                case "--help":
                    opts.infoRequest = .help
                    return opts
                case "--version":
                    opts.infoRequest = .version
                    return opts
                default:
                    throw CLIError.usage("unknown option: \(arg)")
                }
                continue
            }
            if !arg.hasPrefix("-") {
                opts.recipients.append(arg)
                continue
            }

            // Short flag cluster: walk chars after the leading '-'.
            let chars = Array(arg.dropFirst())
            var j = 0
            while j < chars.count {
                let c = chars[j]
                switch c {
                case "t":
                    opts.readRecipientsFromHeaders = true
                    j += 1
                case "i":
                    j += 1 // no-op: ignore lone dot in body
                case "f":
                    let rest = String(chars[(j + 1)...])
                    if !rest.isEmpty {
                        opts.fromAddress = rest
                    } else {
                        guard i < argv.count else {
                            throw CLIError.usage("-f requires an address")
                        }
                        opts.fromAddress = argv[i]
                        i += 1
                    }
                    j = chars.count
                case "F":
                    let rest = String(chars[(j + 1)...])
                    if !rest.isEmpty {
                        opts.fromName = rest
                    } else {
                        guard i < argv.count else {
                            throw CLIError.usage("-F requires a name")
                        }
                        opts.fromName = argv[i]
                        i += 1
                    }
                    j = chars.count
                case "h":
                    // sendmail's hop count, ignored. The value is required and must
                    // be digits: a bare -h at a terminal would otherwise block
                    // reading stdin, and -ht would silently eat the "t".
                    var hopCount = String(chars[(j + 1)...])
                    if hopCount.isEmpty {
                        guard i < argv.count else {
                            throw CLIError.usage("-h requires a hop count (use --help for usage)")
                        }
                        hopCount = argv[i]
                        i += 1
                    }
                    guard !hopCount.isEmpty, hopCount.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                        throw CLIError.usage("bad hop count: \(hopCount)")
                    }
                    j = chars.count
                case "o", "b", "O", "q", "v", "N", "R", "X", "M", "n", "B", "C":
                    // Legacy flags accepted for sendmail compatibility. Some take a
                    // value that in standard sendmail may be SPACE-SEPARATED from the
                    // flag (e.g. -B 8BITMIME, -N never, -R hdrs, -X logfile, -C cf); if the
                    // value isn't attached to this token, it's the next argv. Consume
                    // it so it isn't misparsed as a positional recipient.
                    //
                    // No-value flags (-v verbose, -n no-aliasing) never consume argv.
                    // Attached-only flags (-oi, -bm, -q30m, -Mx=y) just swallow the
                    // rest of this token.
                    let rest = String(chars[(j + 1)...])
                    if separateValueFlags.contains(c) && rest.isEmpty && i < argv.count {
                        i += 1
                    }
                    j = chars.count
                default:
                    throw CLIError.usage("unknown short option: -\(c)")
                }
            }
        }

        return opts
    }

    public static func printHelp(programName: String = "apple-mail-sendmail") {
        print(helpText(programName: programName))
    }

    /// Build the help text. Pure function for testability -- `printHelp` just
    /// writes the result to stdout. Mirrors the section structure used by
    /// swift-argument-parser (OVERVIEW / USAGE / OPTIONS / ENVIRONMENT /
    /// LEGACY FLAGS) without taking the dependency.
    public static func helpText(programName: String = "apple-mail-sendmail") -> String {
        let options: [(String, String)] = [
            ("-t",                  "Read recipients from To, Cc, and Bcc headers."),
            ("-f <addr>",           "Set the From address (Mail.app account selector)."),
            ("-F <name>",           "Set the From display name."),
            ("--send",              "Actually deliver the message. Default is draft for review."),
            ("--help",              "Show this help."),
            ("--version",           "Show version."),
        ]
        let environment: [(String, String)] = [
            ("SENDMAIL_SEND=1",     "Equivalent to --send."),
            ("SENDMAIL_DRY_RUN=1",  "Print the generated AppleScript to stdout instead of executing it. Useful for debugging the message pipeline."),
        ]

        var out = ""
        out += "OVERVIEW: A sendmail-compatible CLI that hands RFC 822 messages to Apple Mail.\n"
        out += "\n"
        out += "  By default, opens a visible compose window for review (does not send).\n"
        out += "  Pass --send (or set SENDMAIL_SEND=1) to deliver instead. HTML email\n"
        out += "  bodies are rendered by Mail itself, so the HTML's own CSS (fonts,\n"
        out += "  colors, tables) is kept; text the CSS does not style falls back to\n"
        out += "  Mail's Fonts & Colors preferences.\n"
        out += "\n"
        out += "USAGE: \(programName) [-t] [-f <addr>] [-F <name>] [--send] [<recipient> ...]\n"
        out += "\n"
        out += "OPTIONS:\n"
        out += formatTwoColumn(options) + "\n"
        out += "\n"
        out += "ENVIRONMENT:\n"
        out += formatTwoColumn(environment) + "\n"
        out += "\n"
        out += "LEGACY FLAGS:\n"
        out += "  Accepted and silently ignored for sendmail compatibility:\n"
        let legacy = "-i, -oi, -bm, -bs, -oem, -oeq, -O*, -q*, -v, -N*, -R*, -X*, -M*, -B*, -C <file>"
        out += wrap(legacy, width: 78, indent: 2).joined(separator: "\n") + "\n"
        out += "  -h <hops> (hop count) is also ignored, but its value must be digits.\n"
        return out
    }

    /// Format a list of (label, description) pairs into a two-column block.
    /// Column 1 indented 2, padded to a common width; column 2 wraps at 80
    /// chars total and continuation lines align under column 2.
    private static func formatTwoColumn(_ rows: [(String, String)]) -> String {
        let labelIndent = "  "
        let labelWidth = max(20, (rows.map { $0.0.count }.max() ?? 0) + 2)
        let gap = "  "
        let descStart = labelIndent.count + labelWidth + gap.count
        let totalWidth = 80
        let descWidth = max(20, totalWidth - descStart)
        var lines: [String] = []
        for (label, desc) in rows {
            let padding = String(repeating: " ", count: max(0, labelWidth - label.count))
            let wrapped = wrap(desc, width: descWidth, indent: descStart)
            // First line carries the label; subsequent wrapped lines start
            // already-indented from `wrap`.
            if let first = wrapped.first {
                lines.append("\(labelIndent)\(label)\(padding)\(gap)\(first.dropFirst(descStart))")
                for rest in wrapped.dropFirst() {
                    lines.append(rest)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Simple greedy word-wrap. Returns each output line already indented by
    /// `indent` spaces (so the caller can splice the first line in place).
    private static func wrap(_ text: String, width: Int, indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        let words = text.split(separator: " ")
        var lines: [String] = []
        var current = ""
        for w in words {
            if current.isEmpty {
                current = String(w)
            } else if current.count + 1 + w.count <= width {
                current += " \(w)"
            } else {
                lines.append("\(pad)\(current)")
                current = String(w)
            }
        }
        if !current.isEmpty {
            lines.append("\(pad)\(current)")
        }
        return lines
    }
}
