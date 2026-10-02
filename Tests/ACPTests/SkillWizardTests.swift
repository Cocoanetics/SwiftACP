@testable import ACPXCore
@testable import acpx
import Foundation
import Testing

/// skill-install's wizard (#294), asked on a pseudo-terminal of 100 columns and 40 rows, colors on.
/// `Fixtures/skill-wizard` holds what acpx 0.19.3 wrote to such a terminal for the same keys, each
/// pressed once the screen before it was there: the wizard writes those screens byte for byte, up
/// to its summary, which shows the machine's paths.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SkillWizardTests {
    struct Recording: Decodable {
        let arguments: [String]
        let keys: [String]
        /// What the terminal showed before the first key, and after each until the summary.
        let screens: [String]
        /// What it showed before the summary, after the key that brought the summary on.
        var beforeSummary: String?
    }

    static func recording(_ name: String) throws -> Recording {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/skill-wizard/\(name).json")
        return try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url))
    }

    /// The agents and scopes asked for, the summary and the install: codex, user.
    @Test func theWizardAsksAsAcpxAsks() throws {
        let scratch = Scratch()
        let run = try replay("codex-user", in: scratch)
        let destination = scratch.home.appendingPathComponent(".codex/skills/acpx").path
        #expect(run.code == 0 && run.err == "Installed acpx to \(destination) (codex/user)\n")
        let ending = "\u{1B}[90m\u{2502}\u{1B}[39m\r\n\u{1B}[32m\u{25C7}\u{1B}[39m  Install complete.\r\n\u{1B}[?25h"
            + "\u{1B}[90m\u{2502}\u{1B}[39m\r\n\u{1B}[90m\u{2514}\u{1B}[39m  Done.\r\n\r\n"
        #expect(Self.withoutSpinnerFrames(run.tail).hasSuffix(ending), "\(run.tail.debugDescription)")
        #expect(run.tail.contains("Planned combinations (1):") && run.tail.contains("Force: no"))
        #expect(FileManager.default.fileExists(atPath: destination + "/SKILL.md"))
    }

    /// The frames the install's spinner drew, and took back, left out of `shown`: there are none
    /// when the install is over within the spinner's first 80 ms, as it was when acpx's ending was
    /// recorded, and one or more when it is not — on a slow CI runner, say — each cleared with
    /// `ESC[1G ESC[J`, after a line break under `CI=true`, as clack's spinner draws and clears them
    /// (``ClackSpinner``). acpx's would draw the same, so the ending is the same either way.
    static func withoutSpinnerFrames(_ shown: String) -> String {
        let frame = "\u{1B}\\[35m[\u{25D2}\u{25D0}\u{25D3}\u{25D1}\u{2022}oO0]\u{1B}\\[39m  Installing 1 target\\.{0,3}"
        let cleared = "(\r\n)?\u{1B}\\[1G\u{1B}\\[J"
        return shown.replacingOccurrences(of: "(\(frame)\(cleared))+", with: "", options: .regularExpression)
    }

    /// One frame drawn under `CI=true`, or three drawn without it, leave acpx's ending; what
    /// drew none is left as it is.
    @Test func spinnerFramesAreLeftOutOfTheEnding() {
        let ending = "\u{1B}[90m\u{2502}\u{1B}[39m\r\n\u{1B}[32m\u{25C7}\u{1B}[39m  Install complete.\r\n\u{1B}[?25h"
        let bar = "\u{1B}[90m\u{2502}\u{1B}[39m\r\n"
        let rest = "\u{1B}[32m\u{25C7}\u{1B}[39m  Install complete.\r\n\u{1B}[?25h"
        let frame = "\u{1B}[35m\u{25D2}\u{1B}[39m  Installing 1 target"
        let onCI = bar + frame + "...\r\n\u{1B}[1G\u{1B}[J" + rest
        #expect(Self.withoutSpinnerFrames(onCI) == ending)
        let frames = frame + "\u{1B}[1G\u{1B}[J\u{1B}[35m\u{25D0}\u{1B}[39m  Installing 1 target\u{1B}[1G\u{1B}[J"
            + "\u{1B}[35m\u{25D3}\u{1B}[39m  Installing 1 target.\u{1B}[1G\u{1B}[J"
        #expect(Self.withoutSpinnerFrames(bar + frames + rest) == ending)
        #expect(Self.withoutSpinnerFrames(ending) == ending)
    }

    /// Ctrl-C at the agents, escape at the scopes: "Install cancelled.", exit code 1, nothing
    /// installed.
    @Test(arguments: ["cancel-agents", "escape-scopes"])
    func aCancelledPromptCancelsTheInstall(_ name: String) throws {
        let scratch = Scratch()
        let run = try replay(name, in: scratch)
        #expect(run.code == 1 && run.err.isEmpty)
        #expect(run.tail.isEmpty, "\(run.tail.debugDescription)")
        #expect(!FileManager.default.fileExists(atPath: scratch.home.appendingPathComponent(".codex").path))
    }

    /// Return with nothing ticked says what to do; a scope never ticked keeps the wizard asking,
    /// until Ctrl-C.
    @Test func nothingTickedIsNotSubmitted() throws {
        let run = try replay("nothing-selected", in: Scratch(), then: ["\u{3}"])
        #expect(run.code == 1 && run.tail.hasSuffix("Install cancelled.\r\n\r\n"), "\(run.tail.debugDescription)")
    }

    /// `--agent` given leaves the agents unasked; `y` answers the force question at once, closing
    /// it as clack's confirm does, twice.
    @Test func aGivenAgentIsNotAskedFor() throws {
        let scratch = Scratch()
        let run = try replay("agent-given", in: scratch)
        #expect(run.code == 0 && run.err.hasSuffix("(claude/repo)\n"), "\(run.err)")
        #expect(run.tail.contains("Force: yes"))
    }

    /// `n` at the last question: "Install cancelled.", nothing installed.
    @Test func aDeclinedInstallIsCancelled() throws {
        let scratch = Scratch()
        let run = try replay("decline", in: scratch)
        #expect(run.code == 1 && run.err.isEmpty)
        #expect(run.tail.hasSuffix("\u{1B}[90m\u{2514}\u{1B}[39m  Install cancelled.\r\n\r\n"))
        #expect(!FileManager.default.fileExists(atPath: scratch.home.appendingPathComponent(".codex").path))
    }

    /// Two agents keeping skills in one place: the wizard refuses before it asks to go ahead.
    @Test func collidingDestinationsAreRefused() throws {
        let scratch = Scratch()
        let run = try replay("collision", in: scratch)
        let destination = scratch.root.appendingPathComponent(".agents/skills/acpx").path
        #expect(run.code == 1)
        #expect(run.err.hasSuffix("""
            Install destination collisions detected:
            - \(destination)
              - acpx @ amp/repo (source: tar stream)
              - acpx @ goose/repo (source: tar stream)
            Resolve collisions by changing skill IDs, sources, --agent, or --scope so each combination has a \
            unique destination.

            """), "\(run.err)")
    }

    /// `a` ticks every agent, `i` none, `a` every one again; the one scope they share is not asked
    /// for; `--force` answers yes to begin with. Five of them keep skills in two places.
    @Test func everyAgentTickedSharesOneScope() throws {
        let run = try replay("every-agent", in: Scratch())
        #expect(run.code == 1)
        #expect(run.err.contains("  - acpx @ portable/repo (source: tar stream)\n  - acpx @ amp/repo"), "\(run.err)")
        #expect(run.err.contains("  - acpx @ vscode/repo (source: tar stream)\n  - acpx @ copilot/repo"), "\(run.err)")
    }

    struct Run {
        let code: Int32
        let err: String
        /// What the terminal showed after the recorded screens.
        let tail: String
    }

    /// The wizard run with the recording's arguments and keys, each screen compared with acpx's
    /// before the next key; `then`, more keys, pressed as the prompts show.
    private func replay(_ name: String, in scratch: Scratch, then more: [String] = []) throws -> Run {
        let recording = try Self.recording(name)
        return try drive(
            recording.arguments, keys: recording.keys + more, expecting: recording.screens,
            beforeSummary: recording.beforeSummary, in: scratch)
    }

    /// `acpx --skill install <arguments>` asking on a pseudo-terminal: each key pressed once the
    /// screen before it is there — the next of `expecting`, compared, or a prompt showing.
    private func drive(
        _ arguments: [String], keys: [String], expecting screens: [String], beforeSummary: String?,
        in scratch: Scratch
    ) throws -> Run {
        let terminal = try PseudoTerminal()
        let capture = Console.Capture()
        let context = scratch.context(in: scratch.root, promptOn: terminal)
        let done = DispatchSemaphore(value: 0)
        let code = CodeBox()
        Thread {
            code.value = ClackText.$colorsGiven.withValue(true) {
                Skillflag.$context.withValue(context) {
                    Console.$capture.withValue(capture) { runCommandLine(["--skill", "install"] + arguments) }
                }
            }
            done.signal()
        }.start()
        var shown = 0
        for (index, key) in keys.enumerated() {
            if index < screens.count {
                let screen = terminal.read(count: screens[index].utf8.count)
                #expect(screen == screens[index], "screen \(index) differs")
                shown += screen.utf8.count
            } else {
                if index == screens.count, let beforeSummary {
                    let screen = terminal.read(count: beforeSummary.utf8.count)
                    #expect(screen == beforeSummary, "the screen before the summary differs")
                    shown += screen.utf8.count
                }
                _ = terminal.read(until: "Proceed with install?")
            }
            terminal.press(key)
        }
        if screens.count > keys.count {
            let last = screens[keys.count]
            #expect(terminal.read(count: last.utf8.count) == last, "the last screen differs")
            shown += last.utf8.count
        }
        // Read on while it finishes: a terminal nobody reads holds up what writes to it.
        let deadline = Date().addingTimeInterval(30)
        while done.wait(timeout: .now()) != .success {
            guard Date() < deadline else { throw CancellationError() }
            terminal.take(for: 50)
        }
        let tail = terminal.rest(after: shown)
        return Run(code: code.value, err: capture.err, tail: tail)
    }
}

/// The exit code a CLI thread returned.
private final class CodeBox: @unchecked Sendable {
    var value: Int32 = -1
}

/// A pseudo-terminal of 100 columns and 40 rows: the wizard asks on its secondary end, and the
/// test reads the screen and presses keys on its primary end.
final class PseudoTerminal: @unchecked Sendable {
    let primary: Int32
    let secondary: Int32
    private var screen = Data()

    init() throws {
        var (primary, secondary): (Int32, Int32) = (0, 0)
        var size = winsize(ws_row: 40, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, nil, nil, &size) == 0 else { throw POSIXError(.EIO) }
        (self.primary, self.secondary) = (primary, secondary)
    }

    deinit {
        close(primary)
        close(secondary)
    }

    func press(_ key: String) {
        _ = key.withCString { write(primary, $0, strlen($0)) }
    }

    /// The next `count` bytes the terminal shows — fewer, should ten seconds pass first.
    func read(count: Int) -> String {
        let start = screen.count
        fill { $0.count - start >= count }
        let end = min(screen.count, start + count)
        return String(decoding: screen[start..<end], as: UTF8.self)
    }

    /// Everything shown until `text` is — or ten seconds pass.
    func read(until text: String) -> String {
        fill { String(decoding: $0, as: UTF8.self).contains(text) }
        return String(decoding: screen, as: UTF8.self)
    }

    /// What the terminal shows within `milliseconds`, kept.
    func take(for milliseconds: Int32) {
        var descriptor = pollfd(fd: primary, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, milliseconds) > 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(primary, &chunk, chunk.count)
        if count > 0 { screen.append(contentsOf: chunk[..<count]) }
    }

    /// What the terminal showed after the first `offset` bytes, once nothing more comes.
    func rest(after offset: Int) -> String {
        fill(idle: true) { _ in false }
        return String(decoding: screen.dropFirst(offset), as: UTF8.self)
    }

    private func fill(idle: Bool = false, until done: (Data) -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !done(screen), Date() < deadline {
            var descriptor = pollfd(fd: primary, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, idle ? 200 : 100) > 0 else {
                if idle { return }
                continue
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(primary, &chunk, chunk.count)
            guard count > 0 else { return }
            screen.append(contentsOf: chunk[..<count])
        }
    }
}

extension Scratch {
    /// The process as skillflag sees it, the wizard asking on `terminal`.
    func context(in directory: URL, promptOn terminal: PseudoTerminal) -> Skillflag.Context {
        var context = context(in: directory, terminal: true)
        let secondary = terminal.secondary
        context.promptTerminal = { ClackTerminal(input: secondary, output: secondary) }
        return context
    }
}
