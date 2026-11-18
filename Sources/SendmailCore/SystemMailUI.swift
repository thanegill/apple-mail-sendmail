import AppKit
import ApplicationServices
import Foundation
import os

private let mailBundleID = "com.apple.mail"

public struct SystemAXClient: AXClient {
    public init() {}

    public func application(pid: Int32) -> UIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        return UIElement(app)
    }

    public func attribute(_ name: String, of element: UIElement) -> AXAttributeValue? {
        guard let axElement = Self.axElement(element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, name as CFString, &value) == .success, let value else { return nil }
        return Self.convert(value)
    }

    public func setAttribute(_ name: String, of element: UIElement, to value: Bool) -> AXError {
        guard let axElement = Self.axElement(element) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(axElement, name as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }

    public func performAction(_ action: String, on element: UIElement) -> AXError {
        guard let axElement = Self.axElement(element) else { return .illegalArgument }
        return AXUIElementPerformAction(axElement, action as CFString)
    }

    static func axElement(_ element: UIElement) -> AXUIElement? {
        let base = element.handle.base as CFTypeRef
        guard CFGetTypeID(base) == AXUIElementGetTypeID() else { return nil }
        return (base as! AXUIElement)
    }

    static func convert(_ value: CFTypeRef) -> AXAttributeValue {
        let typeID = CFGetTypeID(value)
        if typeID == AXUIElementGetTypeID() {
            return .element(UIElement(value as! AXUIElement))
        }
        if typeID == CFArrayGetTypeID() {
            let items = (value as! [CFTypeRef]).filter { CFGetTypeID($0) == AXUIElementGetTypeID() }
            return .elements(items.map { UIElement($0 as! AXUIElement) })
        }
        if typeID == CFBooleanGetTypeID() {
            return .bool(CFBooleanGetValue((value as! CFBoolean)))
        }
        if typeID == CFStringGetTypeID() {
            return .string(value as! String)
        }
        if typeID == CFNumberGetTypeID() {
            return .int((value as! NSNumber).intValue)
        }
        return .unsupported
    }
}

/// Waiting for NSWorkspace's completion handlers needs the `Clock` that
/// pumps the main run loop.
public struct SystemMailWorkspace: MailWorkspace {
    let clock: Clock

    public init(clock: Clock) {
        self.clock = clock
    }

    public func runningMailPID() -> Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: mailBundleID)
            .first { !$0.isTerminated }?.processIdentifier
    }

    public func launchMail(timeout: TimeInterval) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        try waitForLaunchServices(what: "Starting Mail", timeout: timeout) { completion in
            NSWorkspace.shared.openApplication(at: try mailURL(), configuration: configuration) { _, error in completion(error) }
        }
    }

    public func open(_ url: URL, timeout: TimeInterval) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try waitForLaunchServices(what: "Opening the eml in Mail", timeout: timeout) { completion in
            NSWorkspace.shared.open([url], withApplicationAt: try mailURL(), configuration: configuration) { _, error in completion(error) }
        }
    }

    func mailURL() throws -> URL {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mailBundleID) else {
            throw DeliveryError("Launch Services cannot find Mail (\(mailBundleID))")
        }
        return url
    }

    func waitForLaunchServices(
        what: String, timeout: TimeInterval,
        _ start: (@escaping @Sendable (Error?) -> Void) throws -> Void
    ) throws {
        let box = CompletionBox()
        try start { box.finish($0) }
        let deadline = clock.now + timeout
        while !box.isFinished {
            if clock.now >= deadline { throw DeliveryError("\(what) did not complete within \(Int(timeout))s") }
            clock.sleep(0.05)
        }
        if let error = box.error { throw DeliveryError("\(what) failed: \(error.localizedDescription)") }
    }
}

private final class CompletionBox: Sendable {
    private let state = OSAllocatedUnfairLock<(finished: Bool, error: Error?)>(initialState: (false, nil))

    func finish(_ error: Error?) {
        state.withLock { $0 = (true, error) }
    }

    var isFinished: Bool { state.withLock { $0.finished } }

    var error: Error? { state.withLock { $0.error } }
}

/// Wall-clock `Clock` whose sleep runs the main run loop, so NSWorkspace
/// callbacks and running-application state stay current.
public struct SystemClock: Clock {
    public init() {}

    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public func sleep(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if !RunLoop.current.run(mode: .default, before: min(end, Date().addingTimeInterval(0.05))) {
                Thread.sleep(forTimeInterval: min(0.02, max(end.timeIntervalSinceNow, 0)))
            }
        }
    }
}
