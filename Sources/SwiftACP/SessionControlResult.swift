import Foundation
import JSONFoundation

/// What a session control (`setMode`, `setModel`, `setConfigOption`) reports, as
/// acpx's control results do.
public struct SessionControlResult: Codable, Sendable {
    /// Whether the control had to take the session back first: the agent was not
    /// running, and `session/load` or `session/resume` got the session back. `false`
    /// for a session already held, and when a new session replaced one that was gone.
    public var resumed: Bool
    /// The agent's config options after `setConfigOption` (the data the CLI echoes;
    /// may be empty if the agent reports none), when its reply listed them.
    public var configOptions: [JSONValue]? {
        get { rawConfigOptions?.arrayValue }
        set { rawConfigOptions = newValue.map(JSONValue.array) }
    }
    /// The reply's `configOptions` as the agent sent it, whatever it holds: `nil` for a
    /// reply that only acknowledges, and ``JSONValue/null`` when it is `null`.
    public var rawConfigOptions: JSONValue?
    /// Whether the session's owner ran the control, as acpx's queue owner runs one sent while
    /// it holds the session — which acpx's CLI says under `--verbose` (#232). `false` from a
    /// daemon that predates it.
    public var owned: Bool

    public init(resumed: Bool, configOptions: [JSONValue]? = nil, owned: Bool = false) {
        self.resumed = resumed
        self.rawConfigOptions = configOptions.map(JSONValue.array)
        self.owned = owned
    }

    public init(resumed: Bool, rawConfigOptions: JSONValue?, owned: Bool = false) {
        self.resumed = resumed
        self.rawConfigOptions = rawConfigOptions
        self.owned = owned
    }

    private enum CodingKeys: String, CodingKey {
        case resumed, configOptions, owned
    }

    /// Also reads what a daemon from before this result returned: `true` from
    /// `setMode` and `setModel`, the config options from `setConfigOption`. The daemon
    /// outlives the CLI, so one upgraded while such a daemon still runs keeps working
    /// with it. That daemon never says whether it resumed, so `resumed` is `false`.
    public init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            resumed = try keyed.decode(Bool.self, forKey: .resumed)
            rawConfigOptions = try keyed.raw(forKey: .configOptions)
            owned = try keyed.decodeIfPresent(Bool.self, forKey: .owned) ?? false
            return
        }
        let legacy = try decoder.singleValueContainer()
        resumed = false
        owned = false
        if let options = try? legacy.decode([JSONValue].self) {
            rawConfigOptions = .array(options)
        } else {
            _ = try legacy.decode(Bool.self)
            rawConfigOptions = nil
        }
    }

    /// The reply's `configOptions` as sent, `null` included: the CLI echoes it.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resumed, forKey: .resumed)
        try container.encodeIfPresent(rawConfigOptions, forKey: .configOptions)
        if owned { try container.encode(owned, forKey: .owned) }
    }
}
