import ACPXCore
import Foundation

// skill-install's wizard (#294): what `--skill install` asks for on a terminal when `--agent` or
// `--scope` is missing — skillflag 0.2.1's `runInstallWizard`, with @clack/prompts' prompts.
extension SkillInstall {
    /// `agentHints`.
    static let agentHints = [
        "codex": "OpenAI Codex CLI skills (.codex/skills or CODEX_HOME/skills)",
        "claude": "Claude Code skills (.claude/skills)",
        "portable": "Portable agents skills (.agents/skills)",
        "vscode": "VS Code skills in .github/skills",
        "copilot": "GitHub Copilot skills in .github/skills",
        "amp": "Amp agent skills (.agents/skills)",
        "goose": "Goose agent skills (.agents/skills)",
        "opencode": "OpenCode skills (.opencode/skill)",
        "factory": "Factory skills (.factory/skills)",
        "cursor": "Cursor skills (.cursor/skills)"
    ]

    /// `scopeDescriptions`.
    static let scopeDescriptions = [
        "repo": "Install to the current git repo root.",
        "user": "Install to your user-level skills directory.",
        "cwd": "Install relative to the current working directory."
    ]

    /// What the wizard settled: every agent and scope chosen, and whether to overwrite.
    struct Choice {
        let agents: [String]
        let scopes: [String]
        let force: Bool
    }

    /// `runInstallWizard`: the agents asked for unless `--agent` named one, the scopes they share
    /// unless there is only one, whether to overwrite, and — once the plan it makes has no two
    /// installs in one place — whether to go ahead after its summary. `nil` once a prompt is
    /// cancelled or the install declined, "Install cancelled." said.
    static func wizard(
        _ options: Options, ids: [String], on terminal: ClackTerminal, context: Skillflag.Context
    ) throws -> Choice? {
        terminal.intro("skill-install wizard")
        func cancelled() -> Choice? {
            terminal.outro("Install cancelled.")
            return nil
        }
        let given = options.agent.map { [$0] } ?? []
        let valid = Skillflag.unique(given.filter(agents.contains))
        let chosenAgents: [String]
        if !valid.isEmpty, valid.count == Skillflag.unique(given).count {
            chosenAgents = valid
        } else {
            let choices = agents.map { ClackMultiSelect.Option(value: $0, hint: agentHints[$0]) }
            var prompt = ClackPrompt(
                ClackMultiSelect(message: "Agent targets", options: choices, initialValues: valid), on: terminal)
            guard let chosen = prompt.run() else { return cancelled() }
            chosenAgents = Skillflag.unique(chosen.selected)
        }
        let shared = sharedScopes(chosenAgents)
        guard !shared.isEmpty else {
            throw Failure("No shared scopes for selected agents: \(chosenAgents.joined(separator: ", "))")
        }
        let givenScopes = (options.scope.map { [$0] } ?? []).filter { scopes.contains($0) && shared.contains($0) }
        let chosenScopes: [String]
        if shared.count == 1 {
            chosenScopes = shared
        } else {
            let choices = shared.map { ClackMultiSelect.Option(value: $0, hint: scopeDescriptions[$0]) }
            var prompt = ClackPrompt(
                ClackMultiSelect(
                    message: "Scope targets", options: choices, initialValues: Skillflag.unique(givenScopes)),
                on: terminal)
            guard let chosen = prompt.run() else { return cancelled() }
            chosenScopes = Skillflag.unique(chosen.selected)
        }
        let question = "Force overwrite if the destination already exists? (--force)"
        var forcing = ClackPrompt(ClackConfirm(message: question, initialValue: options.force), on: terminal)
        guard let force = forcing.run()?.value else { return cancelled() }
        for agent in chosenAgents {
            for scope in chosenScopes where !supportedScopes(agent).contains(scope) {
                throw Failure("Unsupported agent/scope: \(agent) \(scope)")
            }
        }
        let plan = try plan(ids: ids, agents: chosenAgents, scopes: chosenScopes, context: context)
        try assertNoCollisions(plan)
        terminal.note(summary(ids: ids, agents: chosenAgents, scopes: chosenScopes, plan: plan, force: force),
                      title: "Install summary")
        var proceeding = ClackPrompt(ClackConfirm(message: "Proceed with install?", initialValue: true), on: terminal)
        guard proceeding.run()?.value == true else { return cancelled() }
        return Choice(agents: chosenAgents, scopes: chosenScopes, force: force)
    }

    /// `sharedScopesForAgents`: the first agent's scopes that every agent has.
    static func sharedScopes(_ agents: [String]) -> [String] {
        let unique = Skillflag.unique(agents)
        guard let first = unique.first else { return [] }
        return supportedScopes(first).filter { scope in unique.allSatisfy { supportedScopes($0).contains(scope) } }
    }

    /// The wizard's summary before it asks to go ahead.
    private static func summary(
        ids: [String], agents: [String], scopes: [String], plan: [Target], force: Bool
    ) -> String {
        ([
            "Sources (\(ids.count)):"
        ] + ids.map { "\($0) <= tar stream" } + [
            "Agents (\(agents.count)): \(agents.joined(separator: ", "))",
            "Scopes (\(scopes.count)): \(scopes.joined(separator: ", "))",
            "Matrix: \(ids.count) skill(s) \u{00D7} \(agents.count) agent(s) \u{00D7} \(scopes.count) scope(s) = "
                + "\(plan.count) combination(s)",
            "Execution targets: \(plan.count)",
            "Planned combinations (\(plan.count)):"
        ] + plan.map { "\($0.skill) @ \($0.agent)/\($0.scope) -> \($0.destination)" } + [
            "Force: \(force ? "yes" : "no")"
        ]).joined(separator: "\n")
    }

    /// `assertNoInstallCollisions`: no two installs of the plan in one place.
    static func assertNoCollisions(_ plan: [Target]) throws {
        let byDestination = Dictionary(grouping: plan, by: \.destination).filter { $0.value.count > 1 }
        guard !byDestination.isEmpty else { return }
        var lines = ["Install destination collisions detected:"]
        for destination in byDestination.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            lines.append("- \(destination)")
            for target in byDestination[destination] ?? [] {
                lines.append("  - \(target.skill) @ \(target.agent)/\(target.scope) (source: tar stream)")
            }
        }
        lines.append(
            "Resolve collisions by changing skill IDs, sources, --agent, or --scope so each combination "
                + "has a unique destination.")
        throw Failure(lines.joined(separator: "\n"))
    }
}
