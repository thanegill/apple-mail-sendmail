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
])
