import Foundation
import SendmailCore

let addressTests = TestSuite(name: "AddressParser", cases: [
    TestCase(name: "bare_address") {
        let r = AddressParser.parse("a@x.com")
        try expectEqual(r.count, 1)
        try expectEqual(r[0].address, "a@x.com")
        try expectNil(r[0].displayName)
    },

    TestCase(name: "angle_addr_with_display_name") {
        let r = AddressParser.parse("Alice <a@x.com>")
        try expectEqual(r.count, 1)
        try expectEqual(r[0].displayName, "Alice")
        try expectEqual(r[0].address, "a@x.com")
    },

    TestCase(name: "quoted_display_name") {
        let r = AddressParser.parse("\"Last, First\" <a@x.com>")
        try expectEqual(r.count, 1)
        try expectEqual(r[0].displayName, "Last, First")
        try expectEqual(r[0].address, "a@x.com")
    },

    TestCase(name: "comma_inside_quotes_not_separator") {
        let r = AddressParser.parse("\"Last, First\" <a@x>, b@y")
        try expectEqual(r.count, 2)
        try expectEqual(r[0].displayName, "Last, First")
        try expectEqual(r[1].address, "b@y")
    },

    TestCase(name: "parenthesized_comment_stripped") {
        let r = AddressParser.parse("a@x.com (Alice the Author)")
        try expectEqual(r.count, 1)
        try expectEqual(r[0].address, "a@x.com")
        try expectNil(r[0].displayName)
    },

    TestCase(name: "multiple_addresses") {
        let r = AddressParser.parse("a@x, Bob <b@y>, c@z")
        try expectEqual(r.count, 3)
        try expectEqual(r[0].address, "a@x")
        try expectEqual(r[1].displayName, "Bob")
        try expectEqual(r[1].address, "b@y")
        try expectEqual(r[2].address, "c@z")
    },

    TestCase(name: "encoded_word_display_name_decoded") {
        let r = AddressParser.parse("=?UTF-8?B?SmFuZQ==?= <jane@x>")
        try expectEqual(r.count, 1)
        try expectEqual(r[0].displayName, "Jane")
        try expectEqual(r[0].address, "jane@x")
    },

    TestCase(name: "empty_input_returns_empty") {
        try expect(AddressParser.parse("").isEmpty)
        try expect(AddressParser.parse(",, ,").isEmpty)
    },

    TestCase(name: "malformed_empty_angle_pair_never_yields_empty_address") {
        // `<a@x> <>`: the greedy lastIndex(of:) logic would extract the empty
        // string between the trailing `<>`. The guard must fall back to the
        // token with angle brackets removed, never emit an empty address.
        let r = AddressParser.parse("<a@x> <>")
        try expectEqual(r.count, 1)
        try expect(!r[0].address.isEmpty, "must never emit an empty address")
        try expectEqual(r[0].address, "a@x")
        // Regression: a normal angle address is unaffected.
        let n = AddressParser.parse("Bob <b@y>")
        try expectEqual(n.count, 1)
        try expectEqual(n[0].displayName, "Bob")
        try expectEqual(n[0].address, "b@y")
    },

    TestCase(name: "empty_group_yields_no_addresses") {
        try expect(AddressParser.parse("undisclosed-recipients:;").isEmpty)
        try expect(AddressParser.parse("undisclosed-recipients: ;").isEmpty)
    },

    TestCase(name: "group_yields_member_mailboxes_without_group_name") {
        let r = AddressParser.parse("Team: a@x.test, b@y.test;")
        try expectEqual(r.map(\.address), ["a@x.test", "b@y.test"])
        try expectNil(r[0].displayName)
        try expectNil(r[1].displayName)
    },

    TestCase(name: "group_members_keep_display_names") {
        let r = AddressParser.parse("Team: \"Last, First\" <a@x.test>, Bob <b@y.test>;")
        try expectEqual(r.map(\.address), ["a@x.test", "b@y.test"])
        try expectEqual(r[0].displayName, "Last, First")
        try expectEqual(r[1].displayName, "Bob")
    },

    TestCase(name: "group_mixed_with_plain_mailboxes") {
        let r = AddressParser.parse("Team: a@x.test;, c@z.test")
        try expectEqual(r.map(\.address), ["a@x.test", "c@z.test"])
        let m = AddressParser.parse("first@w.test, Team: a@x.test, b@y.test; , Empty:;, c@z.test")
        try expectEqual(m.map(\.address), ["first@w.test", "a@x.test", "b@y.test", "c@z.test"])
    },

    TestCase(name: "quoted_colon_display_name_is_not_a_group") {
        let single = AddressParser.parse("\"a:b\" <x@y.test>")
        try expectEqual(single.count, 1)
        try expectEqual(single[0].displayName, "a:b")
        try expectEqual(single[0].address, "x@y.test")
        let r = AddressParser.parse("\"Re: x; y\" <x@y.test>, Team: c@z.test;")
        try expectEqual(r.map(\.address), ["x@y.test", "c@z.test"])
        try expectEqual(r[0].displayName, "Re: x; y")
    },

    TestCase(name: "colon_in_nested_comment_is_not_a_group") {
        let r = AddressParser.parse("a@x.test (outer (inner: x;) tail), Team (the (crew: z;) list): b@y.test;")
        try expectEqual(r.map(\.address), ["a@x.test", "b@y.test"])
    },

    TestCase(name: "colon_inside_angle_brackets_is_not_a_group") {
        let r = AddressParser.parse("Bob <b:c@y.test>, Team: d@z.test;")
        try expectEqual(r.map(\.address), ["b:c@y.test", "d@z.test"])
        try expectEqual(r[0].displayName, "Bob")
    },

    TestCase(name: "semicolon_inside_angle_brackets_does_not_close_group") {
        let r = AddressParser.parse("Team: <a;b@x.test>, c@y.test;")
        try expectEqual(r.map(\.address), ["a;b@x.test", "c@y.test"])
    },

    TestCase(name: "ipv6_domain_literal_colons_are_not_a_group") {
        let bare = AddressParser.parse("user@[IPv6:2001:db8::1]")
        try expectEqual(bare.map(\.address), ["user@[IPv6:2001:db8::1]"])
        let angled = AddressParser.parse("Bob <user@[IPv6:2001:db8::1]>, c@z.test")
        try expectEqual(angled.map(\.address), ["user@[IPv6:2001:db8::1]", "c@z.test"])
        try expectEqual(angled[0].displayName, "Bob")
        let grouped = AddressParser.parse("Team: user@[IPv6:2001:db8::1];")
        try expectEqual(grouped.map(\.address), ["user@[IPv6:2001:db8::1]"])
    },

    TestCase(name: "unterminated_group_keeps_members") {
        let r = AddressParser.parse("Team: a@x.test, b@y.test")
        try expectEqual(r.map(\.address), ["a@x.test", "b@y.test"])
    },

    TestCase(name: "adjacent_groups_without_comma") {
        let r = AddressParser.parse("A:a@x.test;B:b@y.test;")
        try expectEqual(r.map(\.address), ["a@x.test", "b@y.test"])
    },

    TestCase(name: "mailbox_after_group_semicolon_without_comma") {
        let r = AddressParser.parse("Team: a@x.test; b@y.test")
        try expectEqual(r.map(\.address), ["a@x.test", "b@y.test"])
    },
])
