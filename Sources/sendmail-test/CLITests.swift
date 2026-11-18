import Foundation
import SendmailCore

private func expectUsageError(
    _ argv: [String],
    containing expectedFragment: String,
    file: StaticString = #file,
    line: UInt = #line
) throws {
    do {
        _ = try CLI.parse(argv, env: [:])
    } catch let CLIError.usage(message) {
        try expect(message.contains(expectedFragment),
                   "usage message '\(message)' lacks '\(expectedFragment)'", file: file, line: line)
        return
    }
    throw TestFailure(message: "expected usage error for \(argv), got success", file: file, line: line)
}

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

    TestCase(name: "C_with_attached_value_does_not_consume_next_arg") {
        let opts = try CLI.parse(["-C/etc/mail.cf", "user@host"], env: [:])
        try expectEqual(opts.recipients, ["user@host"])
    },

    TestCase(name: "dashB_consumes_separate_value_not_recipient") {
        // -B takes a space-separated value (body type). 8BITMIME is the value,
        // not a positional recipient.
        let opts = try CLI.parse(["-B", "8BITMIME", "user@x.com"], env: [:])
        try expectEqual(opts.recipients, ["user@x.com"])
    },

    TestCase(name: "dashN_consumes_separate_value_not_recipient") {
        // -N takes a space-separated value (DSN notify).
        let opts = try CLI.parse(["-N", "never", "user@x.com"], env: [:])
        try expectEqual(opts.recipients, ["user@x.com"])
    },

    TestCase(name: "dashv_takes_no_value") {
        // -v is verbose: it consumes no argv, so the following token is a
        // recipient.
        let opts = try CLI.parse(["-v", "user@x.com"], env: [:])
        try expectEqual(opts.recipients, ["user@x.com"])
    },

    TestCase(name: "attached_only_flags_still_parse") {
        // -oi and -bm carry attached values only and must not consume argv.
        let opts = try CLI.parse(["-oi", "-bm", "user@x.com"], env: [:])
        try expectEqual(opts.recipients, ["user@x.com"])
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

    TestCase(name: "dashh_hop_count_separate_value_ignored") {
        // sendmail's -h N sets the hop count; it must not show help (exit 0
        // without delivering) nor turn N into a recipient.
        let opts = try CLI.parse(["-h", "20", "rcpt@x.test"], env: [:])
        try expectNil(opts.infoRequest)
        try expectEqual(opts.recipients, ["rcpt@x.test"])
    },

    TestCase(name: "dashh_hop_count_attached_value_ignored") {
        let opts = try CLI.parse(["-h20", "rcpt@x.test"], env: [:])
        try expectNil(opts.infoRequest)
        try expectEqual(opts.recipients, ["rcpt@x.test"])
    },

    TestCase(name: "dashth_cluster_takes_hop_count_from_next_arg") {
        let opts = try CLI.parse(["-th", "20", "rcpt@x.test"], env: [:])
        try expect(opts.readRecipientsFromHeaders)
        try expectNil(opts.infoRequest)
        try expectEqual(opts.recipients, ["rcpt@x.test"])
    },

    TestCase(name: "dashh_without_value_is_usage_error") {
        try expectUsageError(["-h"], containing: "-h requires a hop count")
    },

    TestCase(name: "dashh_attached_non_numeric_is_usage_error") {
        // -ht must not silently drop -t by eating "t" as the hop count.
        try expectUsageError(["-ht", "rcpt@x.test"], containing: "bad hop count: t")
    },

    TestCase(name: "dashh_separate_non_numeric_is_usage_error") {
        try expectUsageError(["-h", "abc", "rcpt@x.test"], containing: "bad hop count: abc")
    },

    TestCase(name: "long_help_requests_help") {
        let opts = try CLI.parse(["--help"], env: [:])
        try expectEqual(opts.infoRequest, .help)
    },

    TestCase(name: "help_wins_over_later_args") {
        let opts = try CLI.parse(["--help", "--nope", "user@x.com"], env: [:])
        try expectEqual(opts.infoRequest, .help)
        try expectEqual(opts.recipients, [])
    },

    TestCase(name: "version_flag_requests_version") {
        let opts = try CLI.parse(["--version"], env: [:])
        try expectEqual(opts.infoRequest, .version)
    },

    TestCase(name: "check_permissions_flag_requests_the_permission_check") {
        let opts = try CLI.parse(["--check-permissions"], env: [:])
        try expectEqual(opts.infoRequest, .checkPermissions)
    },

    TestCase(name: "check_permissions_wins_over_later_args") {
        let opts = try CLI.parse(["--check-permissions", "--send", "user@x.com"], env: ["SENDMAIL_SEND": "1"])
        try expectEqual(opts.infoRequest, .checkPermissions)
        try expectEqual(opts.recipients, [])
    },

    TestCase(name: "check_permissions_after_sendmail_flags_still_requests_it") {
        let opts = try CLI.parse(["-oi", "-t", "--check-permissions"], env: [:])
        try expectEqual(opts.infoRequest, .checkPermissions)
    },

    TestCase(name: "check_permissions_misspelled_is_a_usage_error") {
        try expectUsageError(["--check-permission"], containing: "unknown option: --check-permission")
    },

    TestCase(name: "help_text_documents_check_permissions") {
        let h = CLI.helpText(programName: "sendmail")
        try expect(h.contains("       sendmail --check-permissions\n"), "missing the --check-permissions USAGE line")
        let optionLine = h.split(separator: "\n").first { $0.hasPrefix("  --check-permissions ") } ?? ""
        try expect(optionLine.contains("Report whether Accessibility"), "missing --check-permissions in OPTIONS:\n\(h)")
        try expect(h.contains("78 otherwise"), "the option must give its exit codes")
    },

    TestCase(name: "ordinary_parse_has_no_info_request") {
        let opts = try CLI.parse(["-t", "user@x.com"], env: [:])
        try expectNil(opts.infoRequest)
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
        try expect(h.contains("--help"), "missing --help in OPTIONS")
        try expect(h.contains("--version"), "missing --version in OPTIONS")
    },

    TestCase(name: "help_text_lists_dashh_as_legacy_not_help") {
        let h = CLI.helpText()
        try expect(!h.contains("-h, --help"), "-h is the hop-count flag, not help")
        try expect(h.contains("-h <hops>"), "missing -h <hops> in LEGACY FLAGS")
    },

    TestCase(name: "help_text_lists_env_vars") {
        let h = CLI.helpText()
        try expect(h.contains("SENDMAIL_SEND=1"), "missing SENDMAIL_SEND env var")
        try expect(h.contains("SENDMAIL_DRY_RUN=1"), "missing SENDMAIL_DRY_RUN env var")
    },

    TestCase(name: "help_text_does_not_claim_binary_applies_font_prefs") {
        let h = CLI.helpText()
        try expect(!h.contains("Message font"), "help still claims Mail's Message font is applied")
        try expect(h.contains("CSS"), "help should say the HTML's own CSS is kept")
    },

    TestCase(name: "tempfail_exit_code_is_75") {
        // main.swift exits EX_TEMPFAIL when TempDir() creation fails so an MTA
        // retries a transient temp-dir failure instead of bouncing it as a
        // permanent EX_OSERR (71). Guard the constant value.
        try expectEqual(ExitCode.tempFail.rawValue, 75)
        try expectEqual(ExitCode.osErr.rawValue, 71)
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
