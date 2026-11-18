import ApplicationServices
import Foundation

/// Equal handles name the same UI element (for a real `AXUIElement`, by
/// `CFEqual`); the window diff depends on that identity.
public struct UIElement: Hashable {
    public let handle: AnyHashable

    public init(_ handle: AnyHashable) {
        self.handle = handle
    }
}

public enum AXAttributeValue: Equatable {
    case element(UIElement)
    case elements([UIElement])
    case string(String)
    case bool(Bool)
    case int(Int)
    case unsupported
}

public protocol AXClient {
    /// Mail's application element, with a bounded messaging timeout.
    func application(pid: Int32) -> UIElement
    /// nil when the attribute cannot be read.
    func attribute(_ name: String, of element: UIElement) -> AXAttributeValue?
    func setAttribute(_ name: String, of element: UIElement, to value: Bool) -> AXError
    func performAction(_ action: String, on element: UIElement) -> AXError
}

public protocol MailWorkspace {
    func runningMailPID() -> Int32?
    /// Does not activate Mail. Returns once Launch Services has answered.
    func launchMail(timeout: TimeInterval) throws
    /// Activates Mail. Returns once Launch Services has answered.
    func open(_ url: URL, timeout: TimeInterval) throws
}

public protocol Clock {
    /// Monotonic seconds.
    var now: TimeInterval { get }
    func sleep(_ seconds: TimeInterval)
}

extension Clock {
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
    func ensureMailRunning(clock: Clock, timeout: TimeInterval) throws -> Int32 {
        if let pid = runningMailPID() { return pid }
        try launchMail(timeout: timeout)
        guard let pid = clock.poll(timeout: timeout, { runningMailPID() }) else {
            throw DeliveryError("Mail did not start within \(Int(timeout))s")
        }
        return pid
    }
}

public struct DeliveryError: Error, CustomStringConvertible, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
