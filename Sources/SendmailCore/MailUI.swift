import ApplicationServices
import Foundation

/// An accessibility element. Equal handles name the same UI element (for a
/// real `AXUIElement`, by `CFEqual`).
public struct UIElement: Hashable {
    public let handle: AnyHashable

    public init(_ handle: AnyHashable) {
        self.handle = handle
    }
}

/// The attribute values the .eml path reads.
public enum AXAttributeValue: Equatable {
    case element(UIElement)
    case elements([UIElement])
    case string(String)
    case bool(Bool)
    case int(Int)
    case unsupported
}

/// The few Accessibility calls the .eml path makes, so tests can drive a
/// fake Mail instead of the real one.
public protocol AXClient {
    /// Mail's application element, with a bounded messaging timeout.
    func application(pid: Int32) -> UIElement
    /// nil when the attribute cannot be read.
    func attribute(_ name: String, of element: UIElement) -> AXAttributeValue?
    func setAttribute(_ name: String, of element: UIElement, to value: Bool) -> AXError
    func performAction(_ action: String, on element: UIElement) -> AXError
}

/// Launch Services calls: finding, starting and opening files in Mail.
public protocol MailWorkspace {
    func runningMailPID() -> Int32?
    /// Start Mail without bringing it to the front; returns once Launch
    /// Services has answered.
    func launchMail(timeout: TimeInterval) throws
    /// Open `url` with Mail, bringing Mail to the front; returns once Launch
    /// Services has answered.
    func open(_ url: URL, timeout: TimeInterval) throws
}

/// Time for polls and deadlines.
public protocol Clock {
    /// Monotonic seconds.
    var now: TimeInterval { get }
    func sleep(_ seconds: TimeInterval)
}

extension Clock {
    /// Calls `body` until it returns non-nil or `timeout` passes; checks at
    /// least once, and once more at the deadline.
    func poll<T>(timeout: TimeInterval, interval: TimeInterval = 0.1, _ body: () throws -> T?) rethrows -> T? {
        let deadline = now + timeout
        while true {
            if let value = try body() { return value }
            if now >= deadline { return nil }
            sleep(min(interval, max(deadline - now, 0.001)))
        }
    }
}

extension MailWorkspace {
    /// Mail's pid, starting Mail without activating it if it is not running.
    func ensureMailRunning(clock: Clock, timeout: TimeInterval) throws -> Int32 {
        if let pid = runningMailPID() { return pid }
        try launchMail(timeout: timeout)
        guard let pid = clock.poll(timeout: timeout, { runningMailPID() }) else {
            throw DeliveryError("Mail did not start within \(Int(timeout))s")
        }
        return pid
    }
}

/// A failure driving Mail, with the message the user sees.
public struct DeliveryError: Error, CustomStringConvertible, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
