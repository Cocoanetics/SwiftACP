import Foundation
import JSONFoundation

/// The `acpx` runtime-state block of a session record.
///
/// acpx keeps it as a JavaScript object, whose members stay in the order they were first
/// set — and a member set to `undefined` keeps its place — and writes them in that order.
/// ``slots`` follows that order: each field notes its member as it is set, ``forget(_:)``
/// is acpx's `delete`, and ``cloned()`` its `cloneSessionAcpxState`.
public struct SessionAcpxState: Codable, Sendable {
    public var resetOnNextEnsure: Bool? { didSet { place("reset_on_next_ensure") } }
    public var currentModeId: String? { didSet { place("current_mode_id") } }
    public var desiredModeId: String? { didSet { place("desired_mode_id") } }
    public var desiredConfigOptions: [String: String]? { didSet { place("desired_config_options") } }
    public var currentModelId: String? { didSet { place("current_model_id") } }
    public var availableModels: [String]? { didSet { place("available_models") } }
    /// Each advertised model's display name, by model id — acpx's `available_model_names`.
    public var availableModelNames: [String: String]? { didSet { place("available_model_names") } }
    public var modelControl: String? { didSet { place("model_control") } }
    public var availableCommands: [AvailableCommand]? { didSet { place("available_commands") } }
    public var configOptions: JSONValue? { didSet { place("config_options") } }
    public var sessionOptions: SessionOptions? { didSet { place("session_options") } }
    /// The session's own MCP servers (config-file entry shape), persisted as
    /// `mcp_servers`: set by the daemon's `newSession` / `setSessionMcpServers` or by
    /// creating the session under `--mcp-config`, and sent again on every reconnect.
    /// `nil` = the session uses the cwd's config-file servers. (A SwiftACP extension
    /// of the npm record: npm acpx keeps MCP servers per invocation, not per record.)
    public var mcpServers: [McpServerConfig]?
    /// The client capabilities the session was created under — what `--no-fs` and
    /// `--no-terminal` withheld — persisted as `client_capabilities` so every reconnect
    /// advertises the same ones. `nil` = the defaults.
    ///
    /// A SwiftACP extension of the npm record, like `mcp_servers`, and for the same
    /// reason: npm acpx carries capabilities on the queue owner that *is* the session,
    /// while `acpxd` outlives any one connection and has to read them back.
    public var clientCapabilities: PersistedCapabilities?
    /// The member order acpx gave each map of this block that it built anew since the
    /// record was read, by the map's name in the record: `available_model_names` from the
    /// models an agent advertised, `desired_config_options` from a control's reply —
    /// JavaScript objects, built by insertion (``ModelSupport``). A map not here keeps the
    /// order it was read with. Never written.
    var rebuiltOrders: [String: [String]] = [:]
    /// The places of acpx's members in its object, by their names in the record: those
    /// its parser gave a read block, in its order (``parseOrder()``), or those a new block
    /// was given — each since set in a place of its own, last, unless it had one, and
    /// dropped when deleted. A place can outlive its member's value: acpx keeps a member
    /// set to `undefined` where it was. The record's block is written in this order. Never
    /// written itself.
    var slots: [String] = []

    enum CodingKeys: String, CodingKey {
        case resetOnNextEnsure, currentModeId, desiredModeId, desiredConfigOptions, currentModelId
        case availableModels, availableModelNames, modelControl, availableCommands, configOptions
        case sessionOptions, mcpServers, clientCapabilities
    }

    /// The `fs` / `terminal` switches in the record's own shape.
    public struct PersistedCapabilities: Codable, Sendable, Hashable {
        public var readTextFile: Bool
        public var writeTextFile: Bool
        public var terminal: Bool

        public init(readTextFile: Bool, writeTextFile: Bool, terminal: Bool) {
            self.readTextFile = readTextFile
            self.writeTextFile = writeTextFile
            self.terminal = terminal
        }
    }

    /// A persisted slash command. Agents advertise these either as bare strings
    /// (codex: `"debug"`) or as objects (claude: `{name, description, has_input}`).
    /// acpx stores whichever form it received, so we preserve it for round-trip.
    public enum AvailableCommand: Codable, Sendable {
        case bare(String)
        case detailed(Detail)

        /// The object form's fields: name, optional description, and whether
        /// the command takes input.
        public struct Detail: Codable, Sendable {
            public var name: String
            public var description: String?
            public var hasInput: Bool?
        }

        public var name: String {
            switch self {
            case .bare(let name): return name
            case .detailed(let detail): return detail.name
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .bare(string)
            } else {
                self = .detailed(try container.decode(Detail.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .bare(let string): try container.encode(string)
            case .detailed(let detail): try container.encode(detail)
            }
        }
    }

    public struct SessionOptions: Codable, Sendable {
        public var model: String?
        public var allowedTools: [String]?
        public var maxTurns: Int?
        public var systemPrompt: JSONValue? // string | {append}
        /// Environment variables the session's agent is started with, over this
        /// process's — acpx's `session_options.env` (0.14.0). Names keep their case.
        public var env: [String: String]?
        public init() {}

        enum CodingKeys: String, CodingKey {
            case model, allowedTools, maxTurns, systemPrompt, env
        }

        /// Each option read on its own, one that does not read left out; `env` keeps its
        /// string entries and is dropped when none is left — acpx's `storedEnvRecord`.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = (try? container.decodeIfPresent(String.self, forKey: .model)) ?? nil
            allowedTools = (try? container.decodeIfPresent([String].self, forKey: .allowedTools)) ?? nil
            maxTurns = (try? container.decodeIfPresent(Int.self, forKey: .maxTurns)) ?? nil
            systemPrompt = (try? container.decodeIfPresent(JSONValue.self, forKey: .systemPrompt)) ?? nil
            let stored = (try? container.decodeIfPresent([String: JSONValue].self, forKey: .env)) ?? nil
            let strings = (stored ?? [:]).compactMapValues { value -> String? in
                if case .string(let text) = value { return text }
                return nil
            }
            env = strings.isEmpty ? nil : strings
        }
    }

    public init() {}

    /// The member `key` was set: it goes last, unless it has a place already.
    private mutating func place(_ key: String) {
        if !slots.contains(key) { slots.append(key) }
    }

    /// acpx's `delete`: member `key` loses its place, and goes last if it is set again.
    public mutating func forget(_ key: String) {
        slots.removeAll { $0 == key }
    }

    /// acpx's `cloneSessionAcpxState`, which each prompt and each control applies: the
    /// block built anew — its members in the clone's order, each in its place though unset,
    /// `available_model_names` only when present — without `reset_on_next_ensure`, which
    /// the clone does not copy, and with `session_options` built anew too.
    public func cloned() -> SessionAcpxState {
        var clone = self
        clone.resetOnNextEnsure = nil
        clone.slots = ["current_mode_id", "desired_mode_id", "desired_config_options", "current_model_id",
                       "available_models"]
            + (availableModelNames != nil ? ["available_model_names"] : [])
            + ["model_control", "available_commands", "config_options", "session_options"]
        return clone
    }

    /// The order acpx's parser (`parseAcpxState`) gives the members a read block has: a
    /// `model_control` it has to work out lands after `config_options`.
    func parseOrder() -> [String] {
        let present: [(String, Bool)] = [
            ("reset_on_next_ensure", resetOnNextEnsure == true), ("current_mode_id", currentModeId != nil),
            ("desired_mode_id", desiredModeId != nil), ("desired_config_options", desiredConfigOptions != nil),
            ("available_model_names", availableModelNames != nil), ("current_model_id", currentModelId != nil),
            ("available_models", availableModels != nil), ("model_control", modelControl != nil),
            ("config_options", configOptions != nil),
            ("model_control", modelControl == nil && availableModels != nil),
            ("available_commands", availableCommands != nil), ("session_options", sessionOptions != nil)
        ]
        return present.filter(\.1).map(\.0)
    }
}

extension SessionAcpxState {
    /// Each field read on its own, and one that does not read left out rather than failing
    /// the record: acpx drops what it cannot read in this block and keeps the record
    /// (`parseAcpxState`), and so does SwiftACP.
    ///
    /// SwiftACP's own `mcp_servers` and `client_capabilities`, which acpx never reads,
    /// restrict a session, so one that does not read fails closed: no MCP servers rather
    /// than the config file's, and no client capabilities rather than the defaults — a
    /// session created under `--no-fs` must not get the filesystem back.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
        }
        resetOnNextEnsure = field(.resetOnNextEnsure)
        currentModeId = field(.currentModeId)
        desiredModeId = field(.desiredModeId)
        desiredConfigOptions = field(.desiredConfigOptions)
        currentModelId = field(.currentModelId)
        availableModels = field(.availableModels)
        availableModelNames = field(.availableModelNames)
        modelControl = field(.modelControl)
        availableCommands = field(.availableCommands)
        configOptions = field(.configOptions)
        sessionOptions = field(.sessionOptions)
        // `try?` would make an absent field look like one that did not read.
        do {
            mcpServers = try container.decodeIfPresent([McpServerConfig].self, forKey: .mcpServers)
        } catch {
            mcpServers = []
        }
        do {
            clientCapabilities = try container.decodeIfPresent(PersistedCapabilities.self, forKey: .clientCapabilities)
        } catch {
            clientCapabilities = PersistedCapabilities(readTextFile: false, writeTextFile: false, terminal: false)
        }
        // acpx builds a read block anew, in its parser's order.
        slots = parseOrder()
    }
}
