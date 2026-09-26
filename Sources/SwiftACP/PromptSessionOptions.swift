import Foundation
import JSONFoundation

/// acpx's `--model`, `--allowed-tools`, `--max-turns` and `--system-prompt` (or
/// `--append-system-prompt`) for one turn, as its CLI sends them with each prompt
/// (`sessionOptions`). The model is put on the session before the prompt and pinned. When
/// the turn has to connect the session's agent, all of them go out as `_meta` over the
/// options the session was created with, as acpx 0.19.3 sends them (#778); the others are
/// not kept.
@Schema
public struct PromptSessionOptions: Codable, Hashable, Sendable {
    /// The model for this turn.
    public var model: String?
    /// The tools the agent may use, by name.
    public var allowedTools: [String]?
    /// How many turns the agent may take.
    public var maxTurns: Int?
    /// The system prompt, in place of the agent's own.
    public var systemPrompt: String?
    /// What goes after the agent's own system prompt; unused with `systemPrompt`.
    public var appendSystemPrompt: String?

    public init(
        model: String? = nil, allowedTools: [String]? = nil, maxTurns: Int? = nil, systemPrompt: String? = nil,
        appendSystemPrompt: String? = nil
    ) {
        self.model = model
        self.allowedTools = allowedTools
        self.maxTurns = maxTurns
        self.systemPrompt = systemPrompt
        self.appendSystemPrompt = appendSystemPrompt
    }
}
