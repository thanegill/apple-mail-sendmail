import CoreServices
import Foundation

public protocol AppleEventSending {
    /// Throws `AppleEventError` when the event cannot be sent or Mail's
    /// reply carries an error.
    func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor
}

public struct AppleEventError: Error, CustomStringConvertible, Equatable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(message) (\(code))" }
}

public struct SystemAppleEventSender: AppleEventSending {
    /// Explicit: the default and no-timeout flags are reported unreliable for
    /// `sendEvent` (rdar://21477694).
    let timeout: TimeInterval

    public init(timeout: TimeInterval = 120) {
        self.timeout = timeout
    }

    public func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: timeout)
        } catch let error as NSError {
            throw AppleEventError(code: error.code, message: error.localizedDescription)
        }
        return try Self.checked(reply)
    }

    /// Mail reports a failed command in the reply rather than by failing the
    /// send.
    public static func checked(_ reply: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        if let number = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, number != 0 {
            let message = reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue ?? "Mail returned an error"
            throw AppleEventError(code: Int(number), message: message)
        }
        return reply
    }
}

func fourCharCode(_ string: String) -> FourCharCode {
    string.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}

enum AppleEventBuilder {
    static let mailBundleID = "com.apple.mail"

    static func event(_ eventClass: String, _ eventID: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(
            withEventClass: fourCharCode(eventClass),
            eventID: fourCharCode(eventID),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: mailBundleID),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    static func type(_ code: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(typeCode: fourCharCode(code))
    }

    static func enumerated(_ code: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(enumCode: fourCharCode(code))
    }

    static func ordinal(_ code: String) -> NSAppleEventDescriptor {
        var value = fourCharCode(code)
        return NSAppleEventDescriptor(descriptorType: typeAbsoluteOrdinal, bytes: &value, length: MemoryLayout<FourCharCode>.size)!
    }

    static func record(_ fields: [(String, NSAppleEventDescriptor)]) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        for (key, value) in fields {
            record.setDescriptor(value, forKeyword: fourCharCode(key))
        }
        return record
    }

    static func specifier(want: String, of container: NSAppleEventDescriptor, form: String, seld: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        record([
            ("want", type(want)),
            ("from", container),
            ("form", enumerated(form)),
            ("seld", seld),
        ]).coerce(toDescriptorType: typeObjectSpecifier)!
    }

    static func property(_ code: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: "prop", of: container, form: "prop", seld: type(code))
    }

    static func every(_ elementClass: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: elementClass, of: container, form: "indx", seld: ordinal("all "))
    }

    static func last(_ elementClass: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: elementClass, of: container, form: "indx", seld: ordinal("last"))
    }

    static func insertion(_ position: String, _ object: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        record([("kobj", object), ("kpos", enumerated(position))]).coerce(toDescriptorType: typeInsertionLoc)!
    }
}
