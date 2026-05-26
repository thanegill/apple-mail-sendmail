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

func runSuites(_ suites: [TestSuite]) -> Int32 {
    var passed = 0
    var failed = 0
    var failures: [(String, TestFailure)] = []
    var errors: [(String, Error)] = []

    for suite in suites {
        for tc in suite.cases {
            let fullName = "\(suite.name).\(tc.name)"
            do {
                try tc.run()
                passed += 1
                print("PASS  \(fullName)")
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
    print("\(passed + failed) tests, \(passed) passed, \(failed) failed")
    return failed == 0 ? 0 : 1
}
