import Foundation
import JSONFoundation

/// A typed session failure from an agent that speaks the JetBrains AIR extension
/// (`_meta.jetbrains.air.sessionFailure`) — codex-acp reports a provider error that way
/// (`server_overloaded`, a rate limit, an exhausted quota, …) when the client advertises the
/// `sessionFailure` capability (``ClientCapabilities/reportingSessionFailures()``), instead of
/// ending the turn as a plain `end_turn` (#300).
///
/// It rides on the terminal ``PromptResponse/meta`` and on `session_info_update`
/// (``SessionUpdate/sessionFailure``). Every field the adapter sends is kept: the modelled ones
/// below, and the object as sent (``raw``) for any the adapter adds.
public struct SessionFailure: Equatable, Sendable {
    public var id: String?
    public var revision: Int?
    /// What kind of failure, e.g. `service`.
    public var category: String?
    /// `error` for a failure, `warning` for one the adapter is retrying itself (`willRetry`).
    public var severity: String?
    public var title: String?
    /// What the user may do about it: `retry`, ….
    public var actions: [String]
    /// The adapter's own kind (`overloaded`, `rate_limited`, `quota_exhausted`, …) when it sends one.
    public var kind: String?
    public var code: String?
    /// The failure object exactly as the adapter sent it.
    public var raw: JSONValue

    public init(
        id: String? = nil, revision: Int? = nil, category: String? = nil, severity: String? = nil,
        title: String? = nil, actions: [String] = [], kind: String? = nil, code: String? = nil,
        raw: JSONValue = .object([:])
    ) {
        self.id = id
        self.revision = revision
        self.category = category
        self.severity = severity
        self.title = title
        self.actions = actions
        self.kind = kind
        self.code = code
        self.raw = raw
    }

    /// Whether the user can try again: the adapter offers the `retry` action.
    public var isRetryable: Bool { actions.contains("retry") }

    /// Whether this is only a warning (a `willRetry` error the adapter retries itself), not a failure.
    public var isWarning: Bool { severity == "warning" }

    /// A line for the failure: its title, else its kind, else its category.
    public var message: String { title ?? kind ?? category ?? "Session failure" }

    /// The failure in `meta` (`_meta`), if `meta` carries `jetbrains.air.sessionFailure` as an object.
    public init?(meta: JSONValue?) {
        guard case .object(let root)? = meta, case .object(let jetbrains)? = root["jetbrains"],
              case .object(let air)? = jetbrains["air"], case .object(let object)? = air["sessionFailure"]
        else { return nil }
        func string(_ key: String) -> String? {
            if case .string(let text)? = object[key] { return text }
            return nil
        }
        var revision: Int?
        switch object["revision"] {
        case .integer(let number)?: revision = number
        case .double(let number)?: revision = Int(exactly: number)
        default: break
        }
        var actions: [String] = []
        if case .array(let items)? = object["actions"] {
            actions = items.compactMap { if case .string(let text) = $0 { return text } else { return nil } }
        }
        self.init(
            id: string("id"), revision: revision, category: string("category"), severity: string("severity"),
            title: string("title"), actions: actions, kind: string("kind"), code: string("code"),
            raw: .object(object))
    }
}

/// The error a prompt ends with when its agent reported a terminal ``SessionFailure``, in place of
/// the `end_turn` the response says (``PromptResponse/throwingSessionFailure()``).
public struct SessionFailureError: Error, LocalizedError, Equatable, Sendable {
    public var failure: SessionFailure

    public init(_ failure: SessionFailure) { self.failure = failure }

    public var errorDescription: String? { failure.message }
}

extension PromptResponse {
    /// The terminal session failure the agent reported on the response, if any.
    public var sessionFailure: SessionFailure? { SessionFailure(meta: meta) }

    /// The response itself — or, when the agent reported a terminal session failure on it, the
    /// failure as a ``SessionFailureError``: such a turn did not succeed, whatever its stop reason.
    /// A warning (`willRetry`) is not a failure.
    @discardableResult
    public func throwingSessionFailure() throws -> PromptResponse {
        if let failure = sessionFailure, !failure.isWarning { throw SessionFailureError(failure) }
        return self
    }
}

extension SessionUpdate {
    /// The session failure a `session_info_update` carries in its `_meta`, if any; a warning
    /// (``SessionFailure/isWarning``) is one the adapter retries itself.
    public var sessionFailure: SessionFailure? {
        guard case .other("session_info_update", let payload) = self, case .object(let members) = payload
        else { return nil }
        return SessionFailure(meta: members["_meta"])
    }
}

extension ClientCapabilities {
    /// The AIR extension a client declares to get typed session failures
    /// (`jetbrains.air` `{version: 1, capabilities: ["sessionFailure"]}`).
    static let sessionFailureMeta: JSONValue = .object([
        "jetbrains": .object([
            "air": .object(["version": .integer(1), "capabilities": .array([.string("sessionFailure")])])
        ])
    ])

    /// These capabilities declaring that the client takes typed session failures. An opt-in:
    /// codex-acp treats any AIR client as one that takes its AIR tool-call contract, message phases
    /// and goal updates too (`isAirClient`, 2.5.0), so declaring it changes the rest of the event
    /// stream. The launch declares it only to the Codex adapter and withholds it from every other
    /// agent (``AgentLaunchCompat/isCodex(_:_:)``).
    public func reportingSessionFailures() -> ClientCapabilities {
        var capabilities = self
        capabilities.meta = Self.merging(Self.sessionFailureMeta, into: meta)
        return capabilities
    }

    /// Whether the capabilities declare the AIR `sessionFailure` capability.
    var declaresSessionFailures: Bool {
        guard case .object(let root)? = meta, case .object(let jetbrains)? = root["jetbrains"],
              case .object(let air)? = jetbrains["air"], case .array(let list)? = air["capabilities"]
        else { return false }
        return list.contains(.string("sessionFailure"))
    }

    /// These capabilities without the `sessionFailure` declaration: it leaves the list of AIR
    /// capabilities, and the AIR object with it when only its `version` is left.
    func withoutSessionFailures() -> ClientCapabilities {
        guard declaresSessionFailures, case .object(var root)? = meta, case .object(var jetbrains)? = root["jetbrains"],
              case .object(var air)? = jetbrains["air"], case .array(var list)? = air["capabilities"]
        else { return self }
        list.removeAll { $0 == .string("sessionFailure") }
        air["capabilities"] = list.isEmpty ? nil : .array(list)
        if Set(air.keys).isSubset(of: ["version"]) { air = [:] }
        jetbrains["air"] = air.isEmpty ? nil : .object(air)
        root["jetbrains"] = jetbrains.isEmpty ? nil : .object(jetbrains)
        var capabilities = self
        capabilities.meta = root.isEmpty ? nil : .object(root)
        return capabilities
    }

    private static func merging(_ addition: JSONValue, into existing: JSONValue?) -> JSONValue {
        guard case .object(var root)? = existing, case .object(let add) = addition,
              case .object(let addJetbrains)? = add["jetbrains"]
        else { return addition }
        var jetbrains: JSONDictionary = [:]
        if case .object(let current)? = root["jetbrains"] { jetbrains = current }
        var air: JSONDictionary = [:]
        if case .object(let current)? = jetbrains["air"] { air = current }
        if case .object(let addAir)? = addJetbrains["air"] {
            for (key, value) in addAir where key != "capabilities" { air[key] = value }
        }
        var capabilities: JSONArray = []
        if case .array(let current)? = air["capabilities"] { capabilities = current }
        if !capabilities.contains(.string("sessionFailure")) { capabilities.append(.string("sessionFailure")) }
        air["capabilities"] = .array(capabilities)
        jetbrains["air"] = .object(air)
        root["jetbrains"] = .object(jetbrains)
        return .object(root)
    }
}
