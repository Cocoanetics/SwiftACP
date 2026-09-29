@testable import ACPXCore
@testable import acpx
import CryptoKit
import Foundation
import Testing

/// acpx's `--skill` (#249) as acpx 0.19.3 runs it with skillflag 0.2.1. The digests are what acpx
/// 0.19.3 installed from npm gives: `--skill list --json`, and the SHA-256 of `--skill show acpx`.
@Suite struct SkillflagTests {
    /// `acpx --skill list --json`'s digest of the skill acpx 0.19.3 bundles: the SHA-256 of its
    /// `--skill export acpx`.
    static let digest = "sha256:afd95cab8d375c14c1c1304cef1bedafc795c2a85f42afd9b86574272175e9b9"
    /// The SHA-256 of acpx 0.19.3's `skills/acpx/SKILL.md`.
    static let skillSHA256 = "9b3b6ec4fd10455028799a182c31b71b75d35590f7bdcd1d80f45717d6044845"
    static let summary = "Use acpx as a headless ACP CLI for agent-to-agent communication, including "
        + "installed-agent inspection, prompt/exec/sessions workflows, session scoping, queueing, permissions, "
        + "output formats, system-prompt overrides, and multi-agent flows authored with "
        + "defineFlow/decision/decisionEdge."

    @Test func theListIsAcpxs() {
        let scratch = Scratch()
        let text = scratch.acpx(["--skill", "list"])
        #expect(text == SkillRun(code: 0, out: "acpx\t\(Self.summary)\n", err: ""))
        let json = scratch.acpx(["--skill", "list", "--json"])
        #expect(json.code == 0 && json.err.isEmpty)
        #expect(json.out == #"{"skillflag_version":"0.1","skills":[{"id":"acpx","digest":""#
            + Self.digest + #"","files":1,"summary":""# + Self.summary + #""}]}"#)
    }

    @Test func showAndExportGiveAcpxsBytes() {
        let scratch = Scratch()
        let shown = scratch.acpx(["--skill", "show", "acpx"])
        #expect(shown.code == 0 && Self.sha256(shown.outBytes) == Self.skillSHA256)
        let exported = scratch.acpx(["--skill", "export", "acpx"])
        #expect(exported.code == 0 && exported.outBytes.count == 41_472)
        #expect("sha256:" + Self.sha256(exported.outBytes) == Self.digest)
        // The skill's directory found in any case, as on a Mac's file system: named as given.
        let mixed = scratch.acpx(["--skill", "export", "Acpx"])
        #expect(mixed.outBytes.prefix(5) == Data("Acpx/".utf8))
        #expect(Self.sha256(scratch.acpx(["--skill", "show", "ACPX"]).outBytes) == Self.skillSHA256)
    }

    @Test func theHelpIsSkillflags() {
        let help = Scratch().acpx(["--skill", "help"])
        #expect(help.code == 0 && help.err.isEmpty)
        #expect(help.out.hasPrefix("Skillflag help\n\nInstall skillflag globally to get both binaries on your PATH:\n"))
        #expect(help.out.hasSuffix("\n\nFor full details, read docs/SKILLFLAG_SPEC.md.\n"))
    }

    /// skillflag takes `--skill` wherever it is, before anything else but `--version`; a
    /// `--skill=` word is commander's, which knows no such option.
    @Test func skillflagTakesSkillWhereverItIs() {
        let scratch = Scratch()
        let listed = "acpx\t\(Self.summary)\n"
        #expect(scratch.acpx(["--format", "json", "--skill", "list"]).out == listed)
        #expect(scratch.acpx(["prompt", "--skill", "list"]).out == listed)
        #expect(scratch.acpx(["--skill", "list", "--skill", "show", "acpx"]).out == listed)
        #expect(scratch.acpx(["--version", "--skill", "list"]).out == ACPVersion.current + "\n")
        let inline = scratch.acpx(["--skill=list"])
        #expect(inline.code == ExitCodes.usage && inline.out.isEmpty)
        #expect(inline.err.hasPrefix("error: unknown option '--skill=list'\n"), "\(inline.err)")
    }

    @Test(arguments: [
        (["--skill"], "Missing --skill action.\n\(Skillflag.usage)"),
        (["--skill", ""], "Missing --skill action.\n\(Skillflag.usage)"),
        (["--skill", "bogus"], "Unknown --skill action: bogus.\n\(Skillflag.usage)"),
        (["--skill", "show"], "Missing skill id.\n\(Skillflag.usage)"),
        (["--skill", "show", "--json"], "Missing skill id.\n\(Skillflag.usage)"),
        (["--skill", "show", "nope"], "Skill not found: nope"),
        (["--skill", "show", "acpx/"], "Invalid skill id: acpx/"),
        (["--skill", "export", "../x"], "Invalid skill id: ../x"),
        (["--skill", "export", ".."], "Skill id is required."),
        (["--skill", "export", "."], "Skill id is required.")
    ])
    func aWrongActionIsSaidAsSkillflagSaysIt(_ arguments: [String], _ message: String) {
        #expect(Scratch().acpx(arguments) == SkillRun(code: 1, out: "", err: message + "\n"))
    }

    /// Installed where the agent keeps its skills in the scope, as the files an install of acpx
    /// makes: its `SKILL.md` under the skill's name, with the modes a new file and directory get.
    @Test func anInstallPutsTheSkillWhereTheAgentKeepsSkills() throws {
        let scratch = Scratch()
        let install = ["--skill", "install", "acpx", "--agent", "codex", "--scope", "user"]
        let destination = scratch.home.appendingPathComponent(".codex/skills/acpx").path
        let installed = "Installed acpx to \(destination) (codex/user)\n"
        #expect(scratch.acpx(install) == SkillRun(code: 0, out: "", err: installed))
        let file = destination + "/SKILL.md"
        #expect(Self.sha256(try Data(contentsOf: URL(fileURLWithPath: file))) == Self.skillSHA256)
        let mask = Self.umask
        #expect(try Self.mode(destination) == 0o777 & ~mask && Self.mode(file) == 0o666 & ~mask)

        let exists = "Destination already exists: \(destination)\n"
        #expect(scratch.acpx(install) == SkillRun(code: 1, out: "", err: exists))
        try "stale".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(scratch.acpx(install + ["--force"]).code == 0)
        #expect(Self.sha256(try Data(contentsOf: URL(fileURLWithPath: file))) == Self.skillSHA256)
    }

    /// `repo` is the top of the git work tree the directory is in — else the directory itself, git
    /// saying so on stderr each time skill-install looks.
    @Test func theRepoScopeIsTheWorkTreesTop() throws {
        let scratch = Scratch()
        let repo = scratch.root.appendingPathComponent("repo")
        let sub = repo.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Self.git(["init", "-q"], in: repo)
        let top = try #require(Self.realPath(repo.path))
        let inRepo = scratch.acpx(["--skill", "install", "--agent", "claude", "--scope", "repo"], in: sub)
        let installed = "Installed acpx to \(top)/.claude/skills/acpx (claude/repo)\n"
        #expect(inRepo == SkillRun(code: 0, out: "", err: installed))

        let plain = scratch.root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let outside = scratch.acpx(["--skill", "install", "acpx", "--agent", "goose", "--scope", "repo"], in: plain)
        let lines = outside.err.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(outside.code == 0 && lines.count == 4, "\(outside.err)")
        #expect(lines[0] == lines[1] && lines[0].hasPrefix("fatal:"), "\(outside.err)")
        #expect(lines[2] == "Installed acpx to \(plain.path)/.agents/skills/acpx (goose/repo)")
    }

    @Test(arguments: [
        Place("codex", "cwd", "CWD/.codex/skills"),
        Place("codex", "user", "HOME/.codex/skills"),
        Place("codex", "user", "/codex/skills", ["CODEX_HOME": "/codex/"]),
        Place("codex", "user", "skills", ["CODEX_HOME": ""]),
        Place("claude", "user", "HOME/.claude/skills"),
        Place("claude", "user", ".claude/skills", ["HOME": ""]),
        Place("claude", "user", "../.claude/skills", ["HOME": ".."]),
        Place("portable", "user", "HOME/.config/agents/skills"),
        Place("amp", "user", "rel/x/agents/skills", ["XDG_CONFIG_HOME": "rel/x"]),
        Place("opencode", "user", "../a/z/opencode/skill", ["XDG_CONFIG_HOME": "../a/y/../z"]),
        Place("factory", "user", "HOME/.factory/skills"),
        Place("vscode", "repo", "CWD/.github/skills"),
        Place("copilot", "repo", "CWD/.github/skills"),
        Place("opencode", "repo", "CWD/.opencode/skill"),
        Place("factory", "repo", "CWD/.factory/skills"),
        Place("cursor", "repo", "CWD/.cursor/skills")
    ])
    func eachAgentKeepsItsSkillsWhereSkillflagSays(_ place: Place) throws {
        let scratch = Scratch()
        let context = scratch.context(in: scratch.root, environment: place.environment, path: "")
        let root = try SkillInstall.skillsRoot(agent: place.agent, scope: place.scope, context: context)
        let expected = place.expected.replacingOccurrences(of: "CWD", with: scratch.root.path)
            .replacingOccurrences(of: "HOME", with: scratch.home.path)
        #expect(root == expected)
    }

    /// Where an agent keeps its skills for a scope (`scopeResolversByAgent`), from the environment
    /// as Node reads it over the scratch's: `CWD` and `HOME` stand for the scratch's, and a relative
    /// directory stays relative. No git on the `PATH`, `repo` is the directory itself.
    struct Place: Sendable, CustomStringConvertible {
        let agent: String
        let scope: String
        let expected: String
        let environment: [String: String]

        init(_ agent: String, _ scope: String, _ expected: String, _ environment: [String: String] = [:]) {
            (self.agent, self.scope, self.expected, self.environment) = (agent, scope, expected, environment)
        }

        var description: String { "\(agent)/\(scope) \(environment)" }
    }

    @Test(arguments: [
        (["acpx", "--agent", "vscode", "--scope", "user"], "Unsupported agent/scope: vscode user"),
        (["acpx", "--agent", "nope", "--scope", "user"], "Unsupported agent: nope"),
        (["acpx", "--agent", "codex", "--scope", "global"], "Unsupported scope: global"),
        (["acpx"], "Missing required flags.\n\(SkillInstall.usage)"),
        (["acpx", "--agent", "codex"], "Missing required flags.\n\(SkillInstall.usage)"),
        (["acpx", "--agent", "codex", "--agent", "claude", "--scope", "user"], "Only one --agent flag is allowed."),
        (["acpx", "--scope", "user", "--scope", "cwd"], "Only one --scope flag is allowed."),
        (["acpx", "--agent", "codex,claude", "--scope", "user"],
         "Only one value is allowed for --agent. Comma-separated values are not supported."),
        (["acpx", "--agent", "--scope", "user"], "Missing value for --agent."),
        (["acpx", "--scope", "user", "--agent"], "Missing value for --agent."),
        (["acpx", "--agent", " ", "--scope", "user"], "Missing value for --agent."),
        (["acpx", "--agent=codex", "--scope", "cwd"], "Unknown option: --agent=codex"),
        (["-h", "--bogus"], "Unknown option: --bogus"),
        (["nope", "--agent", "codex", "--scope", "user"], "Skill not found: nope"),
        (["acpx", "nope", "a/b", "--agent", "codex", "--scope", "cwd"], "Invalid skill id: a/b"),
        (["nope1", "nope2", "--agent", "codex", "--scope", "cwd"], "Skill not found: nope1"),
        (["acpx", "--agent", "codex", "--scope", "user", "extra"], "PATH cannot be used when install input is preset."),
        (["--agent", "codex", "--scope", "user", "acpx"], "PATH cannot be used when install input is preset.")
    ])
    func aWrongInstallIsSaidAsSkillInstallSaysIt(_ arguments: [String], _ message: String) {
        #expect(Scratch().acpx(["--skill", "install"] + arguments) == SkillRun(code: 1, out: "", err: message + "\n"))
    }

    /// skill-install drains a standard input that is no terminal before it ends on a failure or its
    /// help — never after an install, whose input it never reads.
    @Test func standardInputIsDrainedOnAFailureOrTheHelp() {
        let scratch = Scratch()
        for (arguments, drains) in [
            (["--bogus"], true), (["--help"], true), (["--agent", "codex", "--scope", "cwd"], false)
        ] {
            let drained = Drains()
            let run = scratch.acpx(["--skill", "install"] + arguments, drained: drained)
            #expect(drained.count == (drains ? 1 : 0), "\(arguments) \(run)")
            let atTerminal = Drains()
            _ = scratch.acpx(["--skill", "install"] + arguments, drained: atTerminal, terminal: true)
            #expect(atTerminal.count == 0)
        }
        let help = scratch.acpx(["--skill", "install", "-h"])
        #expect(help == SkillRun(code: 0, out: SkillInstall.usage + "\n", err: ""))
    }

    /// What fails on the file system is said as Node says it: at the directory being made, and with
    /// the name mkdtemp tried.
    @Test func fileSystemFailuresAreSaidAsNodeSaysThem() throws {
        let scratch = Scratch()
        let file = scratch.root.appendingPathComponent("afile").path
        try "text".write(toFile: file, atomically: true, encoding: .utf8)
        let underFile = scratch.acpx(
            ["--skill", "install", "acpx", "--agent", "codex", "--scope", "user"], environment: ["CODEX_HOME": file])
        #expect(underFile == SkillRun(code: 1, out: "", err: "ENOTDIR: not a directory, mkdir '\(file)/skills'\n"))

        let locked = scratch.root.appendingPathComponent("locked/skills")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let denied = scratch.acpx(
            ["--skill", "install", "acpx", "--agent", "codex", "--scope", "user"],
            environment: ["CODEX_HOME": locked.deletingLastPathComponent().path])
        #expect(denied == SkillRun(code: 1, out: "", err: "EACCES: permission denied, mkdir '\(locked.path)/acpx'\n"))

        let noTemporary = scratch.acpx(
            ["--skill", "install", "acpx", "--agent", "codex", "--scope", "cwd"],
            environment: ["TMPDIR": "/nonexistent-skillflag-test/"])
        let prefix = "ENOENT: no such file or directory, mkdtemp '/nonexistent-skillflag-test/skill-install-"
        #expect(noTemporary.code == 1 && noTemporary.err.hasPrefix(prefix) && noTemporary.err.count == prefix.count + 8)
        #expect(!FileManager.default.fileExists(atPath: scratch.root.appendingPathComponent(".codex").path))
    }

    @Test(arguments: [
        (["", ".claude/skills"], ".claude/skills"), (["/a/", "b"], "/a/b"),
        (["..", ".claude/skills"], "../.claude/skills"),
        (["a/../..", "b"], "../b"), (["", ""], "."), (["/x/", "skills/"], "/x/skills/"), (["/", "..", "a"], "/a"),
        (["./a", "./b/."], "a/b"), (["a", "/b"], "a/b")
    ])
    func pathsJoinAsNodeJoinsThem(_ parts: [String], _ joined: String) {
        let result = parts.count == 3
            ? NodePath.joined(parts[0], parts[1], parts[2]) : NodePath.joined(parts[0], parts[1])
        #expect(result == joined)
    }

    @Test(arguments: [("/..", "/"), ("./", "./"), ("a/./b/../../..", ".."), ("//a//b/", "/a/b/"), (".", ".")])
    func pathsNormalizeAsNodeNormalizesThem(_ path: String, _ normalized: String) {
        #expect(NodePath.normalize(path) == normalized)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static var umask: Int {
        let mask = Darwin.umask(0)
        Darwin.umask(mask)
        return Int(mask)
    }

    static func mode(_ path: String) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
    }
}

/// How a run of `acpx --skill …` went.
struct SkillRun: Equatable, CustomStringConvertible {
    let code: Int32
    let out: String
    let err: String
    var outBytes = Data()

    init(code: Int32, out: String, err: String, outBytes: Data = Data()) {
        (self.code, self.out, self.err, self.outBytes) = (code, out, err, outBytes)
    }

    static func == (lhs: SkillRun, rhs: SkillRun) -> Bool {
        (lhs.code, lhs.out, lhs.err) == (rhs.code, rhs.out, rhs.err)
    }

    var description: String { "exit \(code), out \(out.debugDescription), err \(err.debugDescription)" }
}

/// How often standard input was drained.
final class Drains: @unchecked Sendable {
    private let lock = NSLock()
    private var drained = 0
    var count: Int { lock.withLock { drained } }
    func drain() { lock.withLock { drained += 1 } }
}

/// A scratch directory of a test's own, with a home in it, where `acpx --skill` runs.
struct Scratch {
    let root: URL
    let home: URL

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("skillflag-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    /// The process as skillflag sees it: in `directory`, with a `HOME` of the scratch's own and
    /// git kept from looking above the scratch directory, and `environment` over that.
    func context(
        in directory: URL, environment: [String: String] = [:], path: String? = nil,
        drained: Drains? = nil, terminal: Bool = false
    ) -> Skillflag.Context {
        var base = [
            "HOME": home.path, "PATH": path ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "GIT_CEILING_DIRECTORIES": root.deletingLastPathComponent().path
        ]
        base.merge(environment) { _, given in given }
        return Skillflag.Context(
            cwd: directory.path, environment: base, stdinIsTerminal: terminal,
            drainStdin: { drained?.drain() })
    }

    /// `acpx <arguments>` run in `directory` (the scratch directory by default).
    func acpx(
        _ arguments: [String], in directory: URL? = nil, environment: [String: String] = [:],
        drained: Drains? = nil, terminal: Bool = false
    ) -> SkillRun {
        let capture = Console.Capture()
        let context = context(in: directory ?? root, environment: environment, drained: drained, terminal: terminal)
        let code = Skillflag.$context.withValue(context) {
            Console.$capture.withValue(capture) { runCommandLine(arguments) }
        }
        return SkillRun(code: code, out: capture.out, err: capture.err, outBytes: capture.outBytes)
    }
}
