import Foundation
import SendmailCore

let cliTests = TestSuite(name: "CLI", cases: [
    TestCase(name: "dashT_sets_readRecipientsFromHeaders") {
        let opts = try CLI.parse(["-t"], env: [:])
        try expect(opts.readRecipientsFromHeaders)
        try expect(!opts.send)
    },

    TestCase(name: "combined_ti_short_flags") {
        let opts = try CLI.parse(["-ti"], env: [:])
        try expect(opts.readRecipientsFromHeaders)
    },

    TestCase(name: "dashf_separate_arg") {
        let opts = try CLI.parse(["-f", "alice@example.com"], env: [:])
        try expectEqual(opts.fromAddress, "alice@example.com")
    },

    TestCase(name: "dashf_attached_arg") {
        let opts = try CLI.parse(["-falice@example.com"], env: [:])
        try expectEqual(opts.fromAddress, "alice@example.com")
    },

    TestCase(name: "capital_F_full_name") {
        let opts = try CLI.parse(["-F", "Alice Author", "-f", "a@x.com"], env: [:])
        try expectEqual(opts.fromName, "Alice Author")
        try expectEqual(opts.fromAddress, "a@x.com")
    },

    TestCase(name: "send_flag") {
        let opts = try CLI.parse(["--send"], env: [:])
        try expect(opts.send)
    },

    TestCase(name: "env_var_triggers_send") {
        let opts = try CLI.parse([], env: ["SENDMAIL_SEND": "1"])
        try expect(opts.send)
    },

    TestCase(name: "positional_recipients") {
        let opts = try CLI.parse(["a@x.com", "b@y.com"], env: [:])
        try expectEqual(opts.recipients, ["a@x.com", "b@y.com"])
    },

    TestCase(name: "noop_flags_swallowed") {
        let opts = try CLI.parse(["-i", "-oi", "-bm", "-oem", "-OFoo=bar", "-q30m", "-t"], env: [:])
        try expect(opts.readRecipientsFromHeaders)
    },

    TestCase(name: "O_with_separate_arg") {
        let opts = try CLI.parse(["-O", "Foo=bar", "-t"], env: [:])
        try expect(opts.readRecipientsFromHeaders)
    },

    TestCase(name: "C_with_separate_arg") {
        let opts = try CLI.parse(["-C", "/etc/mail.cf", "user@host"], env: [:])
        try expectEqual(opts.recipients, ["user@host"])
    },

    TestCase(name: "double_dash_ends_options") {
        let opts = try CLI.parse(["--", "-not-a-flag@x.com"], env: [:])
        try expectEqual(opts.recipients, ["-not-a-flag@x.com"])
    },

    TestCase(name: "unknown_long_flag_throws") {
        try expectThrows { _ = try CLI.parse(["--nope"], env: [:]) }
    },

    TestCase(name: "unknown_short_flag_throws") {
        try expectThrows { _ = try CLI.parse(["-z"], env: [:]) }
    },

    TestCase(name: "dashf_missing_value_throws") {
        try expectThrows { _ = try CLI.parse(["-f"], env: [:]) }
    },

    TestCase(name: "help_text_has_sap_style_sections") {
        let h = CLI.helpText()
        try expect(h.contains("OVERVIEW:"), "missing OVERVIEW section")
        try expect(h.contains("USAGE:"), "missing USAGE section")
        try expect(h.contains("OPTIONS:"), "missing OPTIONS section")
        try expect(h.contains("ENVIRONMENT:"), "missing ENVIRONMENT section")
        try expect(h.contains("LEGACY FLAGS:"), "missing LEGACY FLAGS section")
    },

    TestCase(name: "help_text_uses_supplied_program_name") {
        let h = CLI.helpText(programName: "sendmail")
        try expect(h.contains("USAGE: sendmail "), "USAGE line did not honor programName")
        try expect(!h.contains("apple-mail-sendmail"), "default program name leaked despite override")
    },

    TestCase(name: "help_text_lists_all_real_options") {
        let h = CLI.helpText()
        try expect(h.contains("-t "), "missing -t in OPTIONS")
        try expect(h.contains("-f <addr>"), "missing -f <addr> in OPTIONS")
        try expect(h.contains("-F <name>"), "missing -F <name> in OPTIONS")
        try expect(h.contains("--send"), "missing --send in OPTIONS")
        try expect(h.contains("-h, --help"), "missing -h/--help in OPTIONS")
        try expect(h.contains("--version"), "missing --version in OPTIONS")
    },

    TestCase(name: "help_text_lists_env_vars") {
        let h = CLI.helpText()
        try expect(h.contains("SENDMAIL_SEND=1"), "missing SENDMAIL_SEND env var")
        try expect(h.contains("SENDMAIL_DRY_RUN=1"), "missing SENDMAIL_DRY_RUN env var")
    },

    TestCase(name: "help_text_wraps_long_descriptions") {
        // Two-column descriptions wrap so column-2 lines stay <= 80. The
        // single-line USAGE synopsis is exempt from wrapping (swift-argument-
        // parser does the same).
        let h = CLI.helpText()
        for line in h.split(separator: "\n") {
            if line.hasPrefix("USAGE:") { continue }
            try expect(line.count <= 80, "line exceeds 80 cols: '\(line)' (\(line.count))")
        }
    },
])
