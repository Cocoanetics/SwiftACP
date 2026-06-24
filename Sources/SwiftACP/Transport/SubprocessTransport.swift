import Foundation

/// How a stdio agent subprocess should be launched.
public struct ProcessLaunch: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]?
    public var workingDirectory: String?
    /// When true (default) the agent's stderr is inherited by this process, so
    /// the adapter's own diagnostics reach the terminal. Set false to silence.
    public var inheritStderr: Bool

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        inheritStderr: Bool = true
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.inheritStderr = inheritStderr
    }
}

public struct ProcessExit: Sendable {
    public var code: Int32
    public var reason: Process.TerminationReason
}

/// A `MessageTransport` backed by a child process speaking JSON-RPC over stdio.
///
/// Inbound lines are read on a dedicated thread doing buffered blocking reads,
/// which keeps token-by-token streaming fast (unlike `FileHandle.AsyncBytes`,
/// which reads a byte at a time).
public final class SubprocessTransport: MessageTransport, @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var isClosed = false
    private var exitResult: ProcessExit?
    private var exitWaiters: [CheckedContinuation<ProcessExit, Never>] = []

    public var processIdentifier: Int32 { process.processIdentifier }

    public init(launch: ProcessLaunch) throws {
        process.executableURL = Self.resolveExecutable(launch.executable)
        process.arguments = launch.arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = launch.inheritStderr ? FileHandle.standardError : nil
        if let env = launch.environment {
            process.environment = env
        }
        if let cwd = launch.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let result = ProcessExit(code: proc.terminationStatus, reason: proc.terminationReason)
            self.stateLock.lock()
            self.exitResult = result
            let waiters = self.exitWaiters
            self.exitWaiters = []
            self.stateLock.unlock()
            for waiter in waiters { waiter.resume(returning: result) }
        }

        do {
            try process.run()
        } catch {
            throw TransportError.launchFailed("\(launch.executable): \(error.localizedDescription)")
        }
    }

    /// Suspends until the child exits, returning its termination status.
    public func waitForExit() async -> ProcessExit {
        await withCheckedContinuation { continuation in
            stateLock.lock()
            if let result = exitResult {
                stateLock.unlock()
                continuation.resume(returning: result)
            } else {
                exitWaiters.append(continuation)
                stateLock.unlock()
            }
        }
    }

    public func makeInboundStream() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let handle = stdoutPipe.fileHandleForReading
            let thread = Thread {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break } // EOF: child closed stdout
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex ..< newline]
                        buffer.removeSubrange(buffer.startIndex ... newline)
                        if lineData.isEmpty { continue }
                        if let line = String(data: lineData, encoding: .utf8) {
                            continuation.yield(line)
                        }
                    }
                }
                if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8),
                    !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    continuation.yield(line)
                }
                continuation.finish()
            }
            thread.name = "acp.transport.reader"
            thread.stackSize = 4 << 20
            thread.start()

            continuation.onTermination = { [weak self] _ in
                self?.close()
            }
        }
    }

    public func write(_ line: String) throws {
        guard var data = line.data(using: .utf8) else { throw TransportError.notUTF8 }
        data.append(0x0A) // newline frame terminator
        writeLock.lock()
        defer { writeLock.unlock() }
        stateLock.lock()
        let closed = isClosed
        stateLock.unlock()
        guard !closed else { throw TransportError.closed }
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    public func close() {
        stateLock.lock()
        if isClosed {
            stateLock.unlock()
            return
        }
        isClosed = true
        stateLock.unlock()

        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }

    /// Forcefully kill the child (used after a graceful terminate times out).
    public func kill() {
        guard process.isRunning else { return }
        #if os(Windows)
        // Windows has no POSIX signals; `Process.terminate()` maps to
        // TerminateProcess, which is itself a forceful kill.
        process.terminate()
        #else
        Foundation.kill(process.processIdentifier, SIGKILL)
        #endif
    }

    private static func resolveExecutable(_ command: String) -> URL {
        if command.contains("/") || command.contains("\\") {
            return URL(fileURLWithPath: command)
        }
        #if os(Windows)
        let separator: Character = ";"
        let defaultPath = ""
        #else
        let separator: Character = ":"
        let defaultPath = "/usr/bin:/bin"
        #endif
        let path = ProcessInfo.processInfo.environment["PATH"] ?? defaultPath
        for directory in path.split(separator: separator) where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: command)
    }
}
