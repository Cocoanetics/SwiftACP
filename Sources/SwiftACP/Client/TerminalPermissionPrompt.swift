import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Bionic)
import Bionic
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(ucrt)
import ucrt
#endif

/// A yes/no question asked on the terminal — acpx's `permission-prompt.ts`.
///
/// - Questions are **serialized**: one is on screen at a time, and the next waits for
///   it (acpx 0.18.0, "serialize interactive permission questions").
/// - A question is asked only when both stdin and stderr are terminals. Otherwise the
///   answer is *no* without anything being printed.
/// - The details and the question go to stderr; the answer is read from stdin, and
///   `y` / `yes` (any case, surrounding space ignored) means yes.
/// - End of input answers *no* — and every later question too, since nothing more can
///   arrive (acpx 0.18.0, "deny waiting questions when stdin closes").
/// - A caller cancelled while queued leaves at once without disturbing the question on
///   screen; one cancelled while its own question is up stops reading stdin.
public final class TerminalPermissionPrompt: @unchecked Sendable {
    /// The process's own terminal: stdin for answers, stderr for questions.
    public static let shared = TerminalPermissionPrompt(
        input: .standardInput, output: .standardError,
        isTerminal: { isatty(0) != 0 && isatty(2) != 0 })

    private let input: FileHandle
    private let output: FileHandle
    private let isTerminal: @Sendable () -> Bool

    private let lock = NSLock()
    /// Set once stdin reports end of input.
    private var inputEnded = false
    /// Bytes read past the end of the last answer, kept for the next question.
    private var pending = Data()
    private var asking = false
    /// Callers queued behind the question on screen, oldest first.
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    /// Called whenever a caller joins the queue — lets a test wait for that instead of
    /// sleeping. Set it before asking.
    private var onEnqueue: (@Sendable () -> Void)?

    func setOnEnqueue(_ hook: (@Sendable () -> Void)?) {
        lock.withLock { onEnqueue = hook }
    }

    /// A prompt over the given handles. `isTerminal` decides whether a question can be
    /// asked at all — tests pass a closure; the shared prompt checks `isatty`.
    public init(
        input: FileHandle, output: FileHandle, isTerminal: @escaping @Sendable () -> Bool
    ) {
        self.input = input
        self.output = output
        self.isTerminal = isTerminal
    }

    /// Whether a question could be asked now: a terminal on both ends, and input not
    /// yet ended.
    public var canPrompt: Bool {
        lock.withLock { !inputEnded } && isTerminal()
    }

    /// Ask a yes/no question. Prints `header` (after a blank line) and `details` when
    /// given, then `prompt`, and waits for an answer.
    public func ask(header: String? = nil, details: String? = nil, prompt: String) async throws -> Bool {
        try Task.checkCancellation()
        guard await acquire() else { throw CancellationError() }
        defer { release() }
        try Task.checkCancellation()
        guard canPrompt else { return false }

        var text = ""
        if let header { text += "\n\(header)\n" }
        if let details, !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\(details)\n"
        }
        text += prompt
        let restoreEcho = suppressControlEcho()
        defer { restoreEcho() }
        output.write(Data(text.utf8))

        guard let answer = try await readLine() else {
            // readline ends the line itself when input closes at a prompt.
            output.write(Data("\n".utf8))
            return false
        }
        let normalized = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "y" || normalized == "yes"
    }

    /// Stop the terminal echoing control characters (`^D`) while the question is up,
    /// and return how to put it back. acpx's readline runs the terminal raw and echoes
    /// the answer itself, so ending input with Ctrl-D shows nothing; in the cooked mode
    /// read here the line discipline would print `^D` over the prompt. Echo of the
    /// answer itself is left on. A no-op when input is not a terminal.
    private func suppressControlEcho() -> () -> Void {
        #if os(Windows)
            return {}
        #else
            let descriptor = input.fileDescriptor
            var saved = termios()
            guard isatty(descriptor) != 0, tcgetattr(descriptor, &saved) == 0 else { return {} }
            var quiet = saved
            quiet.c_lflag &= ~tcflag_t(ECHOCTL)
            guard tcsetattr(descriptor, TCSANOW, &quiet) == 0 else { return {} }
            return { _ = tcsetattr(descriptor, TCSANOW, &saved) }
        #endif
    }

    // MARK: - One question at a time

    /// Wait for the screen. Returns `false` if the caller was cancelled while still
    /// queued: it leaves the queue at once, never having held the slot, so the question
    /// on screen is not disturbed and the next caller keeps its place.
    private func acquire() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let (proceed, enqueued): (Bool, (@Sendable () -> Void)?) = lock.withLock {
                    if asking {
                        waiting.append((id, continuation))
                        return (false, onEnqueue)
                    }
                    asking = true
                    return (true, nil)
                }
                if proceed {
                    continuation.resume(returning: true)
                } else {
                    enqueued?()
                }
            }
        } onCancel: {
            let abandoned: CheckedContinuation<Bool, Never>? = lock.withLock {
                guard let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
                return waiting.remove(at: index).continuation
            }
            abandoned?.resume(returning: false)
        }
    }

    /// Hand the screen to the next caller in line, or free it.
    private func release() {
        let next: CheckedContinuation<Bool, Never>? = lock.withLock {
            if waiting.isEmpty {
                asking = false
                return nil
            }
            return waiting.removeFirst().continuation
        }
        next?.resume(returning: true)
    }

    // MARK: - Reading an answer

    /// The next line from input, or `nil` at end of input. Cancellable: the read stops
    /// at once, and nothing is left listening on stdin.
    private func readLine() async throws -> String? {
        if let line = takeLine() { return line }
        if lock.withLock({ inputEnded }) { return nil }

        let resumed = ResumeOnce<String?>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resumed.set(continuation)
                input.readabilityHandler = { [weak self] handle in
                    guard let self else { return }
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        self.lock.withLock { self.inputEnded = true }
                        resumed.resume(returning: self.takeLine(atEnd: true))
                        return
                    }
                    self.lock.withLock { self.pending.append(chunk) }
                    if let line = self.takeLine() {
                        handle.readabilityHandler = nil
                        resumed.resume(returning: line)
                    }
                }
            }
        } onCancel: {
            input.readabilityHandler = nil
            resumed.resume(throwing: CancellationError())
        }
    }

    /// Take one line off the buffer. At end of input, a final line without a newline
    /// still counts as an answer.
    private func takeLine(atEnd: Bool = false) -> String? {
        lock.withLock {
            if let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex ..< newline]
                pending.removeSubrange(pending.startIndex ... newline)
                return String(decoding: line, as: UTF8.self)
            }
            guard atEnd, !pending.isEmpty else { return nil }
            defer { pending.removeAll() }
            return String(decoding: pending, as: UTF8.self)
        }
    }
}

/// Resumes a continuation at most once, whichever of the read or the cancellation
/// gets there first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var early: Result<Value, Error>?

    func set(_ continuation: CheckedContinuation<Value, Error>) {
        let early: Result<Value, Error>? = lock.withLock {
            if let early = self.early { return early }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func resume(returning value: Value) { finish(.success(value)) }
    func resume(throwing error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>? = lock.withLock {
            guard early == nil else { return nil }
            early = result
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}
