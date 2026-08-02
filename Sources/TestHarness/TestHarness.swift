import Foundation

/// A tiny XCTest-style harness so suites can run under Command Line Tools
/// (which ship neither XCTest nor swift-testing). Tests register themselves and
/// `TestSuite.main` runs them, printing a summary and exiting non-zero on any
/// failure.
public struct TestCase: Sendable {
    public let name: String
    public let body: @Sendable () throws -> Void
    public init(_ name: String, _ body: @escaping @Sendable () throws -> Void) {
        self.name = name
        self.body = body
    }
}

public struct AssertionError: Error, CustomStringConvertible {
    public let message: String
    public let file: StaticString
    public let line: UInt
    public var description: String { "\(file):\(line): \(message)" }
}

public func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expectation failed",
                   file: StaticString = #file, line: UInt = #line) throws {
    if !condition { throw AssertionError(message: message(), file: file, line: line) }
}

public func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: @autoclosure () -> String = "",
                                      file: StaticString = #file, line: UInt = #line) throws {
    if a != b {
        let extra = message().isEmpty ? "" : " — \(message())"
        throw AssertionError(message: "expected \(a) == \(b)\(extra)", file: file, line: line)
    }
}

public func expectNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws {
    if value != nil { throw AssertionError(message: "expected nil, got \(value!)", file: file, line: line) }
}

public func expectNotNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws {
    if value == nil { throw AssertionError(message: "expected non-nil", file: file, line: line) }
}

public func expectThrows(_ body: () throws -> Void, file: StaticString = #file, line: UInt = #line) throws {
    do {
        try body()
        throw AssertionError(message: "expected an error to be thrown", file: file, line: line)
    } catch is AssertionError {
        throw AssertionError(message: "expected an error to be thrown", file: file, line: line)
    } catch {
        // expected
    }
}

/// A simple sink that test files append to from top-level code.
public final class TestCollector: @unchecked Sendable {
    private var cases: [TestCase] = []
    public init() {}
    public func test(_ name: String, _ body: @escaping @Sendable () throws -> Void) {
        cases.append(TestCase(name, body))
    }
    public var all: [TestCase] { cases }
}

public enum TestSuite {
    /// Run the given cases, print a report, and exit the process.
    public static func main(_ name: String, _ cases: [TestCase]) -> Never {
        var failures: [(String, any Error)] = []
        for c in cases {
            // Flush before each test so a fatal trap localizes to this case.
            print("  • \(c.name) ...", terminator: ""); unsafe fflush(stdout)
            do {
                try c.body()
                print("\r  ✓ \(c.name)    ")
            } catch {
                print("\r  ✗ \(c.name)\n      \(error)")
                failures.append((c.name, error))
            }
            unsafe fflush(stdout)
        }
        print("\n\(name): \(cases.count - failures.count)/\(cases.count) passed")
        exit(failures.isEmpty ? 0 : 1)
    }
}
