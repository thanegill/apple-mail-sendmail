import Foundation

struct TestCase {
    let name: String
    let run: () throws -> Void
}

struct TestSuite {
    let name: String
    let cases: [TestCase]
}

struct TestFailure: Error {
    let message: String
    let file: StaticString
    let line: UInt
}

/// Thrown by a test that wants to record itself as skipped (e.g. the
/// environment lacks an OS framework the test needs). The harness reports
/// these separately from passes and failures.
struct TestSkipped: Error {
    let reason: String
}

func skip(_ reason: String) throws -> Never {
    throw TestSkipped(reason: reason)
}

func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String = "expectation failed",
    file: StaticString = #file,
    line: UInt = #line
) throws {
    if !condition() {
        throw TestFailure(message: message(), file: file, line: line)
    }
}

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    file: StaticString = #file,
    line: UInt = #line
) throws {
    if actual != expected {
        throw TestFailure(
            message: "expected \(expected), got \(actual)",
            file: file,
            line: line
        )
    }
}

func expectNil<T>(
    _ value: T?,
    file: StaticString = #file,
    line: UInt = #line
) throws {
    if value != nil {
        throw TestFailure(
            message: "expected nil, got \(value!)",
            file: file,
            line: line
        )
    }
}

func expectNotNil<T>(
    _ value: T?,
    file: StaticString = #file,
    line: UInt = #line
) throws {
    if value == nil {
        throw TestFailure(message: "expected non-nil", file: file, line: line)
    }
}

func expectThrows(
    _ body: () throws -> Void,
    file: StaticString = #file,
    line: UInt = #line
) throws {
    do {
        try body()
    } catch {
        return
    }
    throw TestFailure(message: "expected error, got success", file: file, line: line)
}

/// "Suite.case" of the test currently running, for helpers that record
/// artifacts and need to say which test produced them.
private(set) var currentTestName = ""

func runSuites(_ suites: [TestSuite]) -> Int32 {
    var passed = 0
    var failed = 0
    var skipped = 0
    var failures: [(String, TestFailure)] = []
    var errors: [(String, Error)] = []
    var skips: [(String, String)] = []

    for suite in suites {
        for tc in suite.cases {
            let fullName = "\(suite.name).\(tc.name)"
            currentTestName = fullName
            do {
                try tc.run()
                passed += 1
                print("PASS  \(fullName)")
            } catch let s as TestSkipped {
                skipped += 1
                skips.append((fullName, s.reason))
                print("SKIP  \(fullName)  (\(s.reason))")
            } catch let f as TestFailure {
                failed += 1
                failures.append((fullName, f))
                print("FAIL  \(fullName)")
            } catch {
                failed += 1
                errors.append((fullName, error))
                print("ERR   \(fullName)")
            }
        }
    }

    if !failures.isEmpty || !errors.isEmpty {
        print("")
        for (name, f) in failures {
            print("--- FAIL \(name)")
            print("    \(f.message)")
            print("    at \(f.file):\(f.line)")
        }
        for (name, e) in errors {
            print("--- ERR  \(name)")
            print("    \(e)")
        }
    }

    print("")
    print("\(passed + failed + skipped) tests, \(passed) passed, \(failed) failed, \(skipped) skipped")
    return failed == 0 ? 0 : 1
}
