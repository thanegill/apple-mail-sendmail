import Foundation

public enum InfoRequest: Equatable {
    case help
    case version
    case checkPermissions
}

public struct Options {
    /// When set, the caller prints it and exits without reading stdin.
    public var infoRequest: InfoRequest? = nil
    public var readRecipientsFromHeaders: Bool = false
    public var fromAddress: String? = nil
    public var fromName: String? = nil
    public var send: Bool = false
    /// Drive Mail with Apple Events instead of its windows and menus: plain
    /// text only, and Mail then sends the body quoted (FB11734014).
    public var noUI: Bool = false
    public var recipients: [String] = []

    public init() {}
}

public enum CLIError: Error {
    case usage(String)
}

public enum CLI {
    public static let versionText = "apple-mail-sendmail \(PackageVersion.string)"

    // A value not attached to the flag is the next argv, consumed so it is not
    // taken for a recipient. -v and -n take no value and are deliberately absent.
    private static let separateValueFlags: Set<Character> = ["O", "B", "N", "R", "X", "C"]

    public static func parse(_ argv: [String], env: [String: String]) throws -> Options {
        var opts = Options()
        if env["SENDMAIL_SEND"] == "1" {
            opts.send = true
        }
        if env["SENDMAIL_NO_UI"] == "1" {
            opts.noUI = true
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
                // stdin marker; some callers pass it.
                continue
            }
            if arg.hasPrefix("--") {
                switch arg {
                case "--send":
                    opts.send = true
                case "--no-ui":
                    opts.noUI = true
                case "--help":
                    opts.infoRequest = .help
                    return opts
                case "--version":
                    opts.infoRequest = .version
                    return opts
                case "--check-permissions":
                    opts.infoRequest = .checkPermissions
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

            let chars = Array(arg.dropFirst())
            var j = 0
            while j < chars.count {
                let c = chars[j]
                switch c {
                case "t":
                    opts.readRecipientsFromHeaders = true
                    j += 1
                case "i", "v", "n":
                    j += 1 // no-op: ignore lone dot in body, verbose, no aliasing
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
                case "o", "b", "O", "q", "N", "R", "X", "M", "B", "C":
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

    public static func helpText(programName: String = "apple-mail-sendmail") -> String {
        let options: [(String, String)] = [
            ("-t",                  "Read recipients from To, Cc, and Bcc headers."),
            ("-f <addr>",           "Set the From address (Mail.app account selector)."),
            ("-F <name>",           "Set the From display name. Applies only with -f."),
            ("--send",              "Actually deliver the message. Default is draft for review. The message needs a non-empty Subject; without one the binary exits 65 and sends nothing."),
            ("--no-ui",             "Hand a plain-text message to Mail with Apple Events, without opening or pressing anything in Mail's windows, for cron or launchd jobs where Mail cannot come to the front. Needs Automation for Mail, not Accessibility. Mail sends the body as a quotation (every line prefixed with \"> \"; Mail bug FB11734014). A message with an HTML body is refused (exit 64)."),
            ("--check-permissions", "Report whether Accessibility (needed by default) and Automation for Mail (needed only with --no-ui) are granted, and how to grant them. Exits 0 when both are granted, 78 otherwise. Starts Mail if needed and may show macOS's Automation prompt; sends nothing and reads no stdin."),
            ("--help",              "Show this help."),
            ("--version",           "Show version."),
        ]
        let environment: [(String, String)] = [
            ("SENDMAIL_SEND=1",     "Equivalent to --send."),
            ("SENDMAIL_NO_UI=1",    "Equivalent to --no-ui."),
            ("SENDMAIL_DRY_RUN=1",  "Print the steps that would drive Mail, one JSON object per line, instead of running them. Useful for debugging the message pipeline."),
        ]

        var out = ""
        out += "OVERVIEW: A sendmail-compatible CLI that hands RFC 822 messages to Apple Mail.\n"
        out += "\n"
        out += "  By default, opens a visible compose window for review (does not send).\n"
        out += "  Pass --send (or set SENDMAIL_SEND=1) to deliver instead. Mail opens\n"
        out += "  the message itself and Message > Send Again turns it into a new\n"
        out += "  compose, which needs Accessibility. Plain text arrives as written,\n"
        out += "  and HTML email bodies are rendered by Mail itself, so the HTML's own\n"
        out += "  CSS (fonts, colors, tables) is kept; text the CSS does not style falls\n"
        out += "  back to Mail's Fonts & Colors preferences.\n"
        out += "\n"
        out += "USAGE: \(programName) [-t] [-f <addr>] [-F <name>] [--send] [--no-ui] [<recipient> ...]\n"
        out += "       \(programName) --check-permissions\n"
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
            if let first = wrapped.first {
                lines.append("\(labelIndent)\(label)\(padding)\(gap)\(first.dropFirst(descStart))")
                for rest in wrapped.dropFirst() {
                    lines.append(rest)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Every line, the first included, comes back indented by `indent`.
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
