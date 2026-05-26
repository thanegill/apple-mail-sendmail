import Foundation

public struct Options {
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
    public static func parse(_ argv: [String], env: [String: String], programName: String = "apple-mail-sendmail") throws -> Options {
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
                case "--help", "-h":
                    printHelp(programName: programName)
                    exit(0)
                case "--version":
                    print("apple-mail-sendmail 0.1.0")
                    exit(0)
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
                case "o", "b", "O", "q", "v", "N", "R", "X", "M", "n", "B":
                    // Swallow the rest of this arg (e.g. -oi, -bm, -OFoo=bar, -q30m, -Bmime).
                    // For -O with empty rest, also swallow the next argv (config form).
                    let rest = String(chars[(j + 1)...])
                    if c == "O" && rest.isEmpty && i < argv.count {
                        i += 1
                    }
                    j = chars.count
                case "C":
                    // Config file: takes a value either attached or as next argv.
                    let rest = String(chars[(j + 1)...])
                    if rest.isEmpty && i < argv.count {
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
        let text = """
        usage: \(programName) [-t] [-f addr] [-F name] [--send] [recipient ...]

          Reads an RFC 822 message on stdin and hands it to Apple Mail.
          By default, opens a visible compose window for review (does not send).

        options:
          -t              Read recipients from To, Cc, and Bcc headers.
          -f <addr>       Set the From address (Mail.app account selector).
          -F <name>       Set the From display name.
          --send          Actually deliver the message (default: draft only).
          -h, --help      Show this help.
          --version       Show version.

        env:
          SENDMAIL_SEND=1   Equivalent to --send.

        Many legacy sendmail flags (-i, -oi, -bm, -bs, -O*, -q*, -v, ...)
        are accepted and ignored for compatibility.
        """
        print(text)
    }
}
