import Foundation

public enum RecipientKind: String {
    case to
    case cc
    case bcc

    /// Mail's class code for this kind of recipient.
    var classCode: String {
        switch self {
        case .to: return "trcp"
        case .cc: return "crcp"
        case .bcc: return "brcp"
        }
    }
}

/// One step of the plain path. `PlainPlan.steps` builds the list,
/// `AppleEventPlainDelivery` sends one Apple Event per step after the first,
/// and the dry run prints it, so the printed plan is what a live run does.
public enum PlainStep: Equatable {
    /// Start Mail without activating it if it is not running. No Apple Event.
    case launchMail(timeoutMs: Int)
    /// `make new outgoing message with properties {subject, visible, sender}`.
    /// A nil sender leaves Mail on its default account.
    case makeMessage(subject: String, visible: Bool, sender: String?)
    /// `set content of <message> to <text>`.
    case setContent(String)
    /// `make new <kind> recipient at end of <kind> recipients of <message>`.
    case addRecipient(RecipientKind, address: String, name: String?)
    /// `make new attachment with properties {file name: <file>} at after last
    /// paragraph of content of <message>`.
    case addAttachment(path: String)
    /// `send <message>`.
    case send
}

public enum PlainPlan {
    public static func steps(_ compose: PlainCompose) -> [PlainStep] {
        var steps: [PlainStep] = [
            .launchMail(timeoutMs: 10_000),
            .makeMessage(subject: compose.subject, visible: !compose.send, sender: compose.sender),
            .setContent(compose.body),
        ]
        let recipients: [(RecipientKind, [ParsedAddress])] = [(.to, compose.to), (.cc, compose.cc), (.bcc, compose.bcc)]
        for (kind, addresses) in recipients {
            for address in addresses {
                let name = address.displayName.flatMap { $0.isEmpty ? nil : $0 }
                steps.append(.addRecipient(kind, address: address.address, name: name))
            }
        }
        steps += compose.attachmentURLs.map { .addAttachment(path: $0.path) }
        if compose.send {
            steps.append(.send)
        }
        return steps
    }

    public static func jsonLines(_ steps: [PlainStep]) -> [String] {
        steps.map { planJSONLine(fields($0)) }
    }

    static func fields(_ step: PlainStep) -> [String: Any] {
        switch step {
        case let .launchMail(timeoutMs):
            return ["step": "launch_mail", "activates": false, "timeout_ms": timeoutMs]
        case let .makeMessage(subject, visible, sender):
            return ["step": "make_message", "subject": subject, "visible": visible, "sender": sender ?? NSNull()]
        case let .setContent(text):
            return ["step": "set_content", "text": text]
        case let .addRecipient(kind, address, name):
            return ["step": "add_recipient", "kind": kind.rawValue, "address": address, "name": name ?? NSNull()]
        case let .addAttachment(path):
            return ["step": "add_attachment", "path": path]
        case .send:
            return ["step": "send"]
        }
    }
}

/// The dry run's plain delivery: prints the plan, one JSON object per line,
/// and touches nothing else.
public struct PlainPlanPrinter: PlainDelivery {
    let output: (String) -> Void

    public init(output: @escaping (String) -> Void) {
        self.output = output
    }

    public func deliverPlain(_ compose: PlainCompose) throws {
        for line in PlainPlan.jsonLines(PlainPlan.steps(compose)) {
            output(line)
        }
    }
}

/// The plain path through raw Apple Events to Mail, one per plan step.
/// Needs Automation permission for Mail, as the AppleScript it replaces did.
public struct AppleEventPlainDelivery: PlainDelivery {
    let events: AppleEventSending
    let workspace: MailWorkspace
    let clock: Clock

    public init(events: AppleEventSending, workspace: MailWorkspace, clock: Clock) {
        self.events = events
        self.workspace = workspace
        self.clock = clock
    }

    public func deliverPlain(_ compose: PlainCompose) throws {
        try run(PlainPlan.steps(compose))
    }

    public func run(_ steps: [PlainStep]) throws {
        typealias Build = AppleEventBuilder
        var message: NSAppleEventDescriptor?
        func requireMessage() throws -> NSAppleEventDescriptor {
            guard let message else { throw DeliveryError("internal error: a plain step ran before make_message") }
            return message
        }
        for step in steps {
            switch step {
            case let .launchMail(timeoutMs):
                _ = try workspace.ensureMailRunning(clock: clock, timeout: TimeInterval(timeoutMs) / 1000)
            case let .makeMessage(subject, visible, sender):
                var properties = [("subj", NSAppleEventDescriptor(string: subject)), ("pvis", NSAppleEventDescriptor(boolean: visible))]
                if let sender {
                    properties.append(("sndr", NSAppleEventDescriptor(string: sender)))
                }
                let event = Build.event("core", "crel")
                event.setParam(Build.type("bcke"), forKeyword: keyAEObjectClass)
                event.setParam(Build.record(properties), forKeyword: keyAEPropData)
                let reply = try events.send(event)
                guard let created = reply.paramDescriptor(forKeyword: keyDirectObject),
                      created.descriptorType == typeObjectSpecifier
                else {
                    throw DeliveryError("Mail did not return the new outgoing message")
                }
                message = created
            case let .setContent(text):
                let event = Build.event("core", "setd")
                event.setParam(Build.property("ctnt", of: try requireMessage()), forKeyword: keyDirectObject)
                event.setParam(NSAppleEventDescriptor(string: text), forKeyword: keyAEData)
                _ = try events.send(event)
            case let .addRecipient(kind, address, name):
                var properties = [("radd", NSAppleEventDescriptor(string: address))]
                if let name {
                    properties.append(("pnam", NSAppleEventDescriptor(string: name)))
                }
                let event = Build.event("core", "crel")
                event.setParam(Build.type(kind.classCode), forKeyword: keyAEObjectClass)
                event.setParam(Build.insertion("end ", Build.every(kind.classCode, of: try requireMessage())), forKeyword: keyAEInsertHere)
                event.setParam(Build.record(properties), forKeyword: keyAEPropData)
                _ = try events.send(event)
            case let .addAttachment(path):
                let content = Build.property("ctnt", of: try requireMessage())
                let event = Build.event("core", "crel")
                event.setParam(Build.type("atts"), forKeyword: keyAEObjectClass)
                event.setParam(Build.insertion("afte", Build.last("cpar", of: content)), forKeyword: keyAEInsertHere)
                event.setParam(Build.record([("atfn", NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: path)))]), forKeyword: keyAEPropData)
                _ = try events.send(event)
            case .send:
                let event = Build.event("emsg", "send")
                event.setParam(try requireMessage(), forKeyword: keyDirectObject)
                if Self.replyIsFalse(try events.send(event)) {
                    throw DeliveryError(Self.sendReturnedFalse)
                }
            }
        }
    }

    static let sendReturnedFalse = "Mail.app did not send the message: its send command returned false. Check the sending account and its outgoing mail server in Mail."

    /// True only for a boolean `false` result. A reply with no result, or a
    /// result of another type, says nothing about the send, and failing on it
    /// would make an MTA retry a message Mail may already have sent.
    static func replyIsFalse(_ reply: NSAppleEventDescriptor) -> Bool {
        guard let result = reply.paramDescriptor(forKeyword: keyDirectObject),
              [DescType(typeTrue), DescType(typeFalse), DescType(typeBoolean)].contains(result.descriptorType)
        else { return false }
        return !result.booleanValue
    }
}
