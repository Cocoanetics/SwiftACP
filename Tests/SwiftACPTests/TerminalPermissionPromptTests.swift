@testable import SwiftACP
import Foundation
import Testing

/// The yes/no question asked on the terminal — acpx's `permission-prompt.ts`. Driven
/// through pipes: the prompt is told it has a terminal, and the test types into one
/// pipe and reads what was printed from the other.
@Suite(.timeLimit(.minutes(1)))
struct TerminalPermissionPromptTests {
    /// A prompt over two pipes, plus what it printed so far — awaitable, so a test can
    /// wait for a question to appear instead of sleeping.
    final class Terminal: @unchecked Sendable {
        let keyboard = Pipe()
        let screen = Pipe()
        let prompt: TerminalPermissionPrompt
        private let lock = NSLock()
        private var printed = ""
        private var waiters: [(String, CheckedContinuation<Void, Never>)] = []

        init(isTerminal: Bool = true) {
            prompt = TerminalPermissionPrompt(
                input: keyboard.fileHandleForReading, output: screen.fileHandleForWriting,
                isTerminal: { isTerminal })
            screen.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let chunk = String(decoding: handle.availableData, as: UTF8.self)
                let ready: [CheckedContinuation<Void, Never>] = self.lock.withLock {
                    self.printed += chunk
                    let (met, pending) = self.waiters.partitioned { self.printed.contains($0.0) }
                    self.waiters = pending
                    return met.map(\.1)
                }
                ready.forEach { $0.resume() }
            }
        }

        var output: String { lock.withLock { printed } }

        func type(_ text: String) { keyboard.fileHandleForWriting.write(Data(text.utf8)) }
        func endInput() { try? keyboard.fileHandleForWriting.close() }

        /// Suspend until `text` has been printed.
        func waitFor(_ text: String) async {
            await withCheckedContinuation { continuation in
                let already: Bool = lock.withLock {
                    if printed.contains(text) { return true }
                    waiters.append((text, continuation))
                    return false
                }
                if already { continuation.resume() }
            }
        }
    }

    @Test func aYesIsYesAndTheQuestionIsLaidOutLikeAcpxs() async throws {
        let terminal = Terminal()
        terminal.type("y\n")
        let answer = try await terminal.prompt.ask(
            header: "[permission] Allow write to /w/a.txt?", details: "hello\nworld\n",
            prompt: "Allow write? (y/N) ")
        #expect(answer)
        // `\n<header>\n`, then the details and a newline, then the question.
        await terminal.waitFor("(y/N) ")
        #expect(terminal.output
            == "\n[permission] Allow write to /w/a.txt?\nhello\nworld\n\nAllow write? (y/N) ")
    }

    @Test(arguments: ["y", "Y", "yes", "YES", "  yes  "])
    func answersThatMeanYes(_ typed: String) async throws {
        let terminal = Terminal()
        terminal.type(typed + "\n")
        #expect(try await terminal.prompt.ask(prompt: "? "))
    }

    @Test(arguments: ["n", "no", "sure", "", "yess"])
    func everythingElseMeansNo(_ typed: String) async throws {
        let terminal = Terminal()
        terminal.type(typed + "\n")
        #expect(try await terminal.prompt.ask(prompt: "? ") == false)
    }

    /// Blank details print nothing; a header is preceded by a blank line.
    @Test func blankDetailsAreLeftOut() async throws {
        let terminal = Terminal()
        terminal.type("n\n")
        _ = try await terminal.prompt.ask(header: "H", details: "  \n", prompt: "? ")
        await terminal.waitFor("? ")
        #expect(terminal.output == "\nH\n? ")
    }

    /// End of input answers no, ends the line as readline does — and answers every
    /// later question no at once, without printing it: nothing more can arrive.
    @Test func endOfInputAnswersNoForGood() async throws {
        let terminal = Terminal()
        terminal.endInput()
        #expect(try await terminal.prompt.ask(prompt: "first? ") == false)
        await terminal.waitFor("first? \n")
        #expect(try await terminal.prompt.ask(prompt: "second? ") == false)
        #expect(terminal.prompt.canPrompt == false)
        #expect(terminal.output == "first? \n")
    }

    /// With no terminal on both ends nothing is asked and nothing is printed.
    @Test func withoutATerminalTheAnswerIsNoAndNothingIsPrinted() async throws {
        let terminal = Terminal(isTerminal: false)
        terminal.type("y\n")
        #expect(terminal.prompt.canPrompt == false)
        #expect(try await terminal.prompt.ask(header: "H", prompt: "? ") == false)
        #expect(terminal.output.isEmpty)
    }

    /// One question on screen at a time, and answers go to the questions in order —
    /// a second question neither prints over the first nor takes its answer.
    @Test func questionsAreAskedOneAtATime() async throws {
        let terminal = Terminal()
        let (queued, queuedSignal) = AsyncStream<Void>.makeStream()
        terminal.prompt.setOnEnqueue { queuedSignal.yield() }

        let first = Task { try await terminal.prompt.ask(prompt: "A? ") }
        await terminal.waitFor("A? ")
        let second = Task { try await terminal.prompt.ask(prompt: "B? ") }
        var iterator = queued.makeAsyncIterator()
        _ = await iterator.next()  // the second question is waiting, not printed

        #expect(terminal.output == "A? ")
        terminal.type("y\n")
        #expect(try await first.value)
        await terminal.waitFor("B? ")
        terminal.type("n\n")
        #expect(try await second.value == false)
        #expect(terminal.output == "A? B? ")
    }

    /// A caller cancelled while queued leaves at once — it does not wait for the
    /// question ahead of it — and that question is not disturbed.
    @Test func aQueuedCallerCanBeCancelledWithoutDisturbingTheQuestionOnScreen() async throws {
        let terminal = Terminal()
        let (queued, queuedSignal) = AsyncStream<Void>.makeStream()
        terminal.prompt.setOnEnqueue { queuedSignal.yield() }

        let first = Task { try await terminal.prompt.ask(prompt: "A? ") }
        await terminal.waitFor("A? ")
        let second = Task { try await terminal.prompt.ask(prompt: "B? ") }
        var iterator = queued.makeAsyncIterator()
        _ = await iterator.next()

        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }

        terminal.type("y\n")
        #expect(try await first.value)
        #expect(terminal.output == "A? ")
    }

    /// Typed-ahead input is kept for the next question rather than dropped.
    @Test func typedAheadAnswersAreKeptInOrder() async throws {
        let terminal = Terminal()
        terminal.type("y\nn\n")
        #expect(try await terminal.prompt.ask(prompt: "A? "))
        #expect(try await terminal.prompt.ask(prompt: "B? ") == false)
    }
}

private extension Array {
    func partitioned(_ isMatch: (Element) -> Bool) -> ([Element], [Element]) {
        var matched: [Element] = []
        var rest: [Element] = []
        for element in self {
            if isMatch(element) { matched.append(element) } else { rest.append(element) }
        }
        return (matched, rest)
    }
}
