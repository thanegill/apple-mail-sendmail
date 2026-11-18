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

/// The attribute values the HTML path reads.
public enum AXAttributeValue: Equatable {
    case element(UIElement)
    case elements([UIElement])
    case string(String)
    case bool(Bool)
    case int(Int)
    case unsupported
}

/// The few Accessibility calls the HTML path makes, so tests can drive a
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

/// Time for the HTML path's polls and deadlines.
public protocol Clock {
    /// Monotonic seconds.
    var now: TimeInterval { get }
    func sleep(_ seconds: TimeInterval)
}

/// A failure of the HTML path with the message the user sees.
public struct HTMLDeliveryError: Error, CustomStringConvertible, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
