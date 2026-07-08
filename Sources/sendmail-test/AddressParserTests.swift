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
])
