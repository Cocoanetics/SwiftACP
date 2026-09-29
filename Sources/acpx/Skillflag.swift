import ACPXCore
import Foundation
import SwiftACP

/// acpx's `--skill`: the Skillflag interface (skillflag 0.2.1) over the skill acpx bundles,
/// ``BundledSkill``, which acpx runs before its config and commander, wherever `--skill` is among
/// the arguments (`maybeHandleSkillflag`, #249). The words after the first `--skill` are the action:
/// `list [--json]`, `show <id>`, `export <id>`, `help`, or `install [<id> ...]` followed by
/// skill-install's own arguments (``SkillInstall``). A failure is its message on stderr, exit code 1.
enum Skillflag {
    /// What skillflag reads of the process: its directory, its environment and its standard input.
    /// A test runs the CLI in a context of its own (``context``).
    struct Context: Sendable {
        var cwd: String
        var environment: [String: String]
        /// Whether standard input is a terminal.
        var stdinIsTerminal: Bool
        /// Reads standard input to its end, as skillflag drains a pipe it leaves unread before it
        /// exits, so that what writes to it does not fail.
        var drainStdin: @Sendable () -> Void

        static var process: Context {
            Context(
                cwd: physicalCWD(), environment: ProcessInfo.processInfo.environment,
                stdinIsTerminal: isatty(STDIN_FILENO) != 0,
                drainStdin: { _ = try? FileHandle.standardInput.readToEnd() })
        }
    }

    /// The context a test runs the CLI in; `nil` for the process's own.
    @TaskLocal static var context: Context?

    /// A failure skillflag reports with its message alone (`SkillflagError`, `InstallError`).
    struct Failure: Error, Equatable {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }

    /// Whether skillflag takes the arguments: `--skill` among them, as a word of its own. acpx also
    /// loads skillflag for a word that starts with `--skill=`, but skillflag takes only `--skill`, so
    /// `--skill=list` goes on to commander, which knows no such option.
    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains("--skill")
    }

    /// Runs the action the words after `--skill` name (`handleSkillflag`), returning the exit code.
    static func run(_ arguments: [String]) -> Int32 {
        let context = Self.context ?? .process
        do {
            switch try Action(arguments) {
            case .list(let json):
                list(json: json)
            case .show(let id):
                _ = try skill(id)
                Console.out(BundledSkill.markdown)
            case .export(let id):
                Console.outBytes(SkillBundle.tar(id: try skill(id)))
            case .help:
                Console.out(helpText + "\n")
            case .install(let ids, let arguments):
                return SkillInstall.run(ids: try installIds(ids), arguments: arguments, context: context)
            }
            return ExitCodes.success
        } catch let failure as Failure {
            Console.err(failure.message + "\n")
            return ExitCodes.error
        } catch {
            Console.err(error.localizedDescription + "\n")
            return ExitCodes.error
        }
    }

    /// What `--skill` is asked to do (`parseSkillArgs`).
    enum Action: Equatable {
        case install(ids: [String]?, arguments: [String])
        case list(json: Bool)
        case help
        case export(String)
        case show(String)

        /// The action named by the words after the first `--skill`.
        init(_ arguments: [String]) throws {
            let words = arguments.firstIndex(of: "--skill").map { Array(arguments[($0 + 1)...]) } ?? arguments
            guard let action = words.first, !action.isEmpty, !action.hasPrefix("-") else {
                throw Failure("Missing --skill action.\n\(Skillflag.usage)")
            }
            switch action {
            case "install":
                self = Self.install(Array(words.dropFirst()))
            case "list":
                self = .list(json: words.dropFirst().contains("--json"))
            case "help":
                self = .help
            case "export", "show":
                guard words.count > 1, !words[1].isEmpty, !words[1].hasPrefix("-") else {
                    throw Failure("Missing skill id.\n\(Skillflag.usage)")
                }
                self = action == "export" ? .export(words[1]) : .show(words[1])
            default:
                throw Failure("Unknown --skill action: \(action).\n\(Skillflag.usage)")
            }
        }

        /// `parseInstallIds`: the ids up to the first word that starts with `-` — each a list with
        /// commas, trimmed, the empty ones left out, each id once — and skill-install's arguments.
        private static func install(_ words: [String]) -> Action {
            let named = words.prefix { !$0.hasPrefix("-") }
            let ids = named.flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
                .map { String($0).javaScriptTrimmed }
                .filter { !$0.isEmpty }
            return .install(ids: ids.isEmpty ? nil : unique(ids), arguments: Array(words.dropFirst(named.count)))
        }
    }

    /// skillflag's usage, which its errors about the action end with.
    static let usage = """
        Usage:
          --skill install [<id> ...] [--agent <agent>] [--scope <scope>] [--force]
          --skill list [--json]
          --skill export <id>
          --skill show <id>
          --skill help
        """

    /// `SKILLFLAG_HELP_TEXT`.
    static let helpText = """
        Skillflag help

        Install skillflag globally to get both binaries on your PATH:
          npm install -g skillflag

        Prefer not to install globally? Use npx for one-off runs:
          npx skillflag list
          npx skillflag install --agent codex --scope repo < ./skill.tar

        List available skills:
          tool --skill list
          tool --skill list --json

        Show a skill's documentation:
          tool --skill show <id>

        Export a skill bundle:
          tool --skill export <id>

        Install a skill bundle:
          tool --skill install [<id> ...] [--agent <agent>] [--scope <scope>]
          tool --skill export <id> | skill-install --agent <agent> --scope <scope>

        For full details, read docs/SKILLFLAG_SPEC.md.
        """

    /// `--skill list`: each skill's id, a tab and its summary; with `--json`, skillflag's listing of
    /// each with its bundle's digest, and no line break after it.
    private static func list(json: Bool) {
        let summary = SkillBundle.summary
        guard json else {
            Console.out(summary.map { "\(BundledSkill.id)\t\($0)" } ?? BundledSkill.id)
            Console.out("\n")
            return
        }
        var members = [
            WireJSON.Member("id", .text(BundledSkill.id)),
            WireJSON.Member("digest", .text(SkillBundle.digest(id: BundledSkill.id))),
            WireJSON.Member("files", .number(Double(SkillBundle.fileCount)))
        ]
        if let summary { members.append(WireJSON.Member("summary", .text(summary))) }
        if let version = SkillBundle.frontmatter["version"] {
            members.append(WireJSON.Member("version", .text(version)))
        }
        let listing = WireJSON.object([
            WireJSON.Member("skillflag_version", .text("0.1")),
            WireJSON.Member("skills", .array([.object(members)]))
        ])
        Console.out(listing.stringified)
    }

    /// The skill `id` names, as the id was given: skillflag finds a skill as its directory under the
    /// skills acpx ships (`resolveSkillDirFromRoots`) — in any case of its letters, on the file
    /// system a Mac has by default, which ignores case.
    static func skill(_ id: String) throws -> String {
        guard !id.isEmpty, id != ".", id != ".." else { throw Failure("Skill id is required.") }
        guard !id.contains("/"), !id.contains("\\") else { throw Failure("Invalid skill id: \(id)") }
        guard id.allSatisfy(\.isASCII), id.lowercased() == BundledSkill.id else {
            throw Failure("Skill not found: \(id)")
        }
        return id
    }

    /// The skills `--skill install` installs: those named, else every skill acpx ships — the one.
    /// skillflag looks for all the named ones at once: a malformed id fails before one not found.
    private static func installIds(_ ids: [String]?) throws -> [String] {
        guard let ids else { return [BundledSkill.id] }
        for id in ids where id.isEmpty || id == "." || id == ".." || id.contains("/") || id.contains("\\") {
            _ = try skill(id)
        }
        return try ids.map(skill)
    }

    /// `uniqueValues`: each value once, in the order first seen.
    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
