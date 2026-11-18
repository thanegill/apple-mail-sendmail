import CoreServices
import Foundation
import SendmailCore

indirect enum AEValue: Equatable, Sendable, CustomStringConvertible {
    case text(String)
    case bool(Bool)
    case integer(Int)
    case type(String)
    case enumerated(String)
    case ordinal(String)
    case fileURL(String)
    case null
    case record([String: AEValue])
    case specifier(want: String, from: AEValue, form: String, seld: AEValue)
    case insertion(position: String, object: AEValue)
    case unknown(String)

    var description: String {
        switch self {
        case let .text(value): return "\"\(value)\""
        case let .bool(value): return "\(value)"
        case let .integer(value): return "\(value)"
        case let .type(code): return "type(\(code))"
        case let .enumerated(code): return "enum(\(code))"
        case let .ordinal(code): return "ordinal(\(code))"
        case let .fileURL(path): return "file(\(path))"
        case .null: return "null"
        case let .record(fields): return "{" + fields.keys.sorted().map { "\($0): \(fields[$0]!)" }.joined(separator: ", ") + "}"
        case let .specifier(want, from, form, seld): return "spec(\(want) \(form) \(seld) of \(from))"
        case let .insertion(position, object): return "insl(\(position) \(object))"
        case let .unknown(type): return "unknown(\(type))"
        }
    }

    var texts: [String] {
        switch self {
        case let .text(value): return [value]
        case let .record(fields): return fields.values.flatMap(\.texts)
        case let .specifier(_, from, _, seld): return from.texts + seld.texts
        case let .insertion(_, object): return object.texts
        default: return []
        }
    }
}

func codeString(_ code: FourCharCode) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "\(code)"
}

func decodeAE(_ descriptor: NSAppleEventDescriptor) -> AEValue {
    switch codeString(descriptor.descriptorType) {
    case "utxt", "TEXT", "utf8":
        return .text(descriptor.stringValue ?? "")
    case "true", "fals", "bool":
        return .bool(descriptor.booleanValue)
    case "long", "shor":
        return .integer(Int(descriptor.int32Value))
    case "type":
        return .type(codeString(descriptor.typeCodeValue))
    case "enum":
        return .enumerated(codeString(descriptor.enumCodeValue))
    case "abso":
        let data = descriptor.data
        guard data.count == 4 else { return .unknown("abso") }
        return .ordinal(codeString(data.withUnsafeBytes { $0.loadUnaligned(as: FourCharCode.self) }))
    case "furl":
        return .fileURL(descriptor.fileURLValue?.path ?? "")
    case "null":
        return .null
    case "reco":
        return .record(recordFields(descriptor))
    case "obj ":
        guard let record = descriptor.coerce(toDescriptorType: typeAERecord) else { return .unknown("obj ") }
        let fields = recordFields(record)
        guard case let .type(want)? = fields["want"], case let .enumerated(form)? = fields["form"],
              let from = fields["from"], let seld = fields["seld"]
        else { return .unknown("obj ") }
        return .specifier(want: want, from: from, form: form, seld: seld)
    case "insl":
        guard let record = descriptor.coerce(toDescriptorType: typeAERecord) else { return .unknown("insl") }
        let fields = recordFields(record)
        guard case let .enumerated(position)? = fields["kpos"], let object = fields["kobj"] else { return .unknown("insl") }
        return .insertion(position: position, object: object)
    case let other:
        return .unknown(other)
    }
}

private func recordFields(_ record: NSAppleEventDescriptor) -> [String: AEValue] {
    var fields: [String: AEValue] = [:]
    guard record.numberOfItems > 0 else { return fields }
    for index in 1...record.numberOfItems {
        if let item = record.atIndex(index) {
            fields[codeString(record.keywordForDescriptor(at: index))] = decodeAE(item)
        }
    }
    return fields
}

struct RecordedEvent: CustomStringConvertible {
    let eventClass: String
    let eventID: String
    let target: String?
    let params: [String: AEValue]

    var name: String { "\(eventClass)/\(eventID)" }
    var description: String { "\(name) " + AEValue.record(params).description }
}

/// As Mail answers `make new outgoing message`:
/// `outgoing message id 7 of application "Mail"`.
let recordedMessageSpecifier = AEValue.specifier(want: "bcke", from: .null, form: "ID  ", seld: .integer(7))

final class AppleEventRecorder: AppleEventSending {
    private(set) var events: [RecordedEvent] = []
    /// 0-based event index.
    var failure: (index: Int, error: AppleEventError)?
    /// Runs before each event is answered.
    var onSend: ((RecordedEvent) throws -> Void)?
    var replyWithoutMessage = false
    /// The direct object of Mail's reply to `send`; nil leaves it out.
    var sendResult: NSAppleEventDescriptor?

    func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        var params: [String: AEValue] = [:]
        if event.numberOfItems > 0 {
            for index in 1...event.numberOfItems {
                if let item = event.atIndex(index) {
                    params[codeString(event.keywordForDescriptor(at: index))] = decodeAE(item)
                }
            }
        }
        let recorded = RecordedEvent(
            eventClass: codeString(event.eventClass),
            eventID: codeString(event.eventID),
            target: event.attributeDescriptor(forKeyword: keyAddressAttr).flatMap { String(data: $0.data, encoding: .utf8) },
            params: params
        )
        let index = events.count
        events.append(recorded)
        try onSend?(recorded)
        if let failure, failure.index == index { throw failure.error }
        let reply = NSAppleEventDescriptor.appleEvent(
            withEventClass: kCoreEventClass, eventID: kAEAnswer, targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        if recorded.name == "core/crel", params["kocl"] == .type("bcke"), !replyWithoutMessage {
            reply.setParam(Self.messageSpecifier(), forKeyword: keyDirectObject)
        }
        if recorded.name == "emsg/send", let sendResult {
            reply.setParam(sendResult, forKeyword: keyDirectObject)
        }
        return reply
    }

    static func messageSpecifier() -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC("bcke")), forKeyword: fourCC("want"))
        record.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: fourCC("from"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: fourCC("ID  ")), forKeyword: fourCC("form"))
        record.setDescriptor(NSAppleEventDescriptor(int32: 7), forKeyword: fourCC("seld"))
        return record.coerce(toDescriptorType: typeObjectSpecifier)!
    }

    // MARK: Lookups

    var names: [String] { events.map(\.name) }

    var messageProperties: [String: AEValue] {
        guard let make = events.first(where: { $0.name == "core/crel" && $0.params["kocl"] == .type("bcke") }),
              case let .record(fields)? = make.params["prdt"]
        else { return [:] }
        return fields
    }

    func creations(of elementClass: String) -> [RecordedEvent] {
        events.filter { $0.name == "core/crel" && $0.params["kocl"] == .type(elementClass) }
    }

    var allTexts: [String] { events.flatMap { AEValue.record($0.params).texts } }
}

func fourCC(_ string: String) -> FourCharCode {
    string.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}
