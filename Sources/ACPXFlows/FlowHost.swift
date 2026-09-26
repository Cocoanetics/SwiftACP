import Foundation
import JSONRPCWire
import SwiftACP

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The Node process that loads a flow file and calls the node callbacks it defines, for
/// the Swift runner (see `scripts/flow-host/flow-host.mjs`). acpx runs flow code inside
/// its own process; the host is where SwiftACP runs it.
///
/// It speaks newline-delimited JSON-RPC 2.0 over a socket on its file descriptor 3, and
/// keeps this process's standard input and output, so what the flow prints lands where
/// it does under acpx. The host ignores SIGINT, SIGTERM and SIGHUP — the runner handles
/// those, as acpx's does — and exits when told to, or when this process's end of the
/// socket closes. A host that exits of its own accord — the flow's `process.exit()`, or
/// a crash — takes acpx's own process with it in acpx: ``Exited`` says it is gone, and
/// ``stop()`` how it went.
///
/// Values cross as ``WireJSON``, which keeps object members in the order JavaScript gave
/// them, as the run bundle has to.
public final class FlowHost: @unchecked Sendable {
    /// What a callback threw, as acpx's runner records it.
    public struct CallbackError: Error, LocalizedError, Equatable {
        /// `error.message` for an `Error`, else `String(value)`.
        public let message: String
        /// Whether the value thrown was an `Error`.
        public let isError: Bool

        public var errorDescription: String? { message }
    }

    /// The host's end of the socket closed — it has exited, or is exiting — with a request
    /// unanswered.
    public struct Exited: Error, LocalizedError {
        public var errorDescription: String? { "The flow host exited" }
    }

    /// Handles a request the host sends the runner (`shell/run`).
    public typealias RequestHandler = @Sendable (_ method: String, _ params: WireJSON?) async throws -> WireJSON

    private let socket: Int32
    private let pid: pid_t
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<WireJSON?, Error>] = [:]
    private var ended = false
    private var requestHandler: RequestHandler?
    /// The host's wait status once it is reaped — under the lock, so that until then its
    /// pid is still this process's to signal.
    private var waitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []

    private init(socket: Int32, pid: pid_t) {
        self.socket = socket
        self.pid = pid
    }

    deinit {
        close(socket)
    }

    /// Start the host with `node`, in `cwd`, with `environment`.
    public static func start(node: String, cwd: String, environment: [String: String]) throws -> FlowHost {
        let scripts = try FlowHostFiles.install()
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        // A write once the host is gone fails with `EPIPE`, not `SIGPIPE`, which would end
        // this process then and there, not as the host ended.
        _ = fcntl(descriptors[0], F_SETNOSIGPIPE, 1)
        var hostEnvironment = environment
        hostEnvironment["ACPX_FLOW_RUNTIME"] = scripts.runtime
        hostEnvironment["ACPX_FLOW_SUCRASE"] = scripts.sucrase
        hostEnvironment["ACPX_FLOW_FD"] = "3"
        let pid: pid_t
        do {
            pid = try spawn(
                node, arguments: [node, scripts.host], cwd: cwd, environment: hostEnvironment, channel: descriptors[1])
        } catch {
            close(descriptors[0])
            close(descriptors[1])
            throw error
        }
        close(descriptors[1])
        let host = FlowHost(socket: descriptors[0], pid: pid)
        host.startReading()
        host.startWaiting()
        return host
    }

    /// Answer the host's own requests with `handler`.
    public func setRequestHandler(_ handler: RequestHandler?) {
        lock.withLock { requestHandler = handler }
    }

    /// Send `method` and wait for its result — `nil` for JSON `null`. A callback's thrown
    /// value arrives as ``CallbackError``.
    public func request(_ method: String, _ params: WireJSON? = nil) async throws -> WireJSON? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WireJSON?, Error>) in
            let id: Int? = lock.withLock {
                guard !ended else { return nil }
                let id = nextId
                nextId += 1
                pending[id] = continuation
                return id
            }
            guard let id else {
                continuation.resume(throwing: Exited())
                return
            }
            do {
                try write(.object([
                    ("jsonrpc", .text("2.0")), ("id", .number(Double(id))), ("method", .text(method)),
                    ("params", params)
                ]))
            } catch {
                let waiting = lock.withLock { pending.removeValue(forKey: id) }
                waiting?.resume(throwing: error)
            }
        }
    }

    /// Send `method` without waiting for anything back.
    public func notify(_ method: String, _ params: WireJSON? = nil) {
        try? write(.object([("jsonrpc", .text("2.0")), ("method", .text(method)), ("params", params)]))
    }

    /// Ask the host to exit, and make sure it has: a host still running a second later —
    /// one whose callback holds its event loop — is killed. Returns its wait status: how it
    /// ended, asked to or of its own accord.
    @discardableResult
    public func stop() async -> Int32 {
        notify("host/exit")
        if await exitStatus(within: .seconds(1)) == nil {
            lock.withLock {
                if waitStatus == nil { _ = kill(pid, SIGKILL) }
            }
        }
        let status = await exitStatus()
        shutdown(socket, SHUT_RDWR)
        return status
    }

    /// The exit code that ends a process as the host ended: its own, or — killed by a
    /// signal — 128 and the signal's number, as a shell reports that.
    public static func exitCode(waitStatus status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    /// The host's wait status, once it has exited.
    private func exitStatus() async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let status: Int32? = lock.withLock {
                if let waitStatus { return waitStatus }
                exitWaiters.append(continuation)
                return nil
            }
            if let status { continuation.resume(returning: status) }
        }
    }

    /// The host's wait status, if it exits within `timeout`. Whichever comes first ends
    /// the wait; a task group would wait for the other too.
    private func exitStatus(within timeout: Duration) async -> Int32? {
        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32?, Error>) in
            let first = FirstResult(continuation)
            let deadline = Task {
                try? await Task.sleep(for: timeout)
                first.settle(.success(nil))
            }
            Task {
                let status = await self.exitStatus()
                deadline.cancel()
                first.settle(.success(status))
            }
        }
    }

    // MARK: - Wire

    private let writeLock = NSLock()

    private func write(_ message: WireJSON) throws {
        let line = Array((message.stringified + "\n").utf8)
        try writeLock.withLock {
            var offset = 0
            while offset < line.count {
                let written = line[offset...].withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) }
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE)
                }
                offset += written
            }
        }
    }

    private func startReading() {
        let socket = self.socket
        let thread = Thread { [self] in
            var framing = LineFraming()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(socket, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                do {
                    try framing.push(Data(buffer[0..<count])) { body in
                        if let message = WireJSON(parsing: body) { received(message) }
                    }
                } catch {
                    break
                }
            }
            end()
        }
        thread.name = "acpx.flow-host.reader"
        thread.start()
    }

    private func received(_ message: WireJSON) {
        if let method = message["method"]?.stringValue {
            // The host's own request: answered in a task of its own, as the host keeps
            // reading while one waits on the runner.
            let id = message["id"]
            let handler = lock.withLock { requestHandler }
            Task {
                do {
                    guard let handler else { throw FlowHostError.methodNotFound(method) }
                    let result = try await handler(method, message["params"])
                    if let id { try? write(.object([("jsonrpc", .text("2.0")), ("id", id), ("result", result)])) }
                } catch {
                    guard let id else { return }
                    try? write(.object([
                        ("jsonrpc", .text("2.0")), ("id", id),
                        ("error", .object([
                            ("code", .number(-32000)), ("message", .text(TurnFailureText.message(of: error)))
                        ]))
                    ]))
                }
            }
            return
        }
        guard case .number(let raw)? = message["id"], let id = Int(exactly: raw) else { return }
        let waiting = lock.withLock { pending.removeValue(forKey: id) }
        guard let waiting else { return }
        if let error = message["error"] {
            let data = error["data"]
            waiting.resume(throwing: CallbackError(
                message: error["message"]?.stringValue ?? "",
                isError: data?["isError"] == .bool(true)))
        } else {
            let result = message["result"]
            waiting.resume(returning: result == .null ? nil : result)
        }
    }

    private func end() {
        let waiting: [CheckedContinuation<WireJSON?, Error>] = lock.withLock {
            ended = true
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        for continuation in waiting { continuation.resume(throwing: Exited()) }
    }

    /// Wait for the host to exit, on a thread of its own, without reaping it (`WNOWAIT`);
    /// then reap it under the lock, and hand its status to whoever waits for it.
    private func startWaiting() {
        let pid = self.pid
        let thread = Thread { [self] in
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0 {
                guard errno == EINTR else { break }
            }
            let (status, waiters): (Int32, [CheckedContinuation<Int32, Never>]) = lock.withLock {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                waitStatus = status
                defer { exitWaiters.removeAll() }
                return (status, exitWaiters)
            }
            for waiter in waiters { waiter.resume(returning: status) }
        }
        thread.name = "acpx.flow-host.exit"
        thread.start()
    }

    // MARK: - Spawning

    /// Start `executable` with this process's standard descriptors and `channel` as its
    /// descriptor 3, nothing else inherited.
    private static func spawn(
        _ executable: String, arguments: [String], cwd: String, environment: [String: String], channel: Int32
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        for descriptor: Int32 in [0, 1, 2] { posix_spawn_file_actions_adddup2(&actions, descriptor, descriptor) }
        posix_spawn_file_actions_adddup2(&actions, channel, 3)
        guard posix_spawn_file_actions_addchdir_np(&actions, cwd) == 0 else { throw POSIXError(.ENOENT) }
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        sigdelset(&everySignal, SIGKILL)
        sigdelset(&everySignal, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let environmentLines = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let status = withCStrings(arguments) { argv in
            withCStrings(environmentLines) { envp in posix_spawn(&pid, executable, &actions, &attributes, argv, envp) }
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
        return pid
    }

    private static func withCStrings<R>(
        _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers { free(pointer) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

enum FlowHostError: Error, LocalizedError {
    case methodNotFound(String)

    var errorDescription: String? {
        switch self {
        case .methodNotFound(let method): return "Method not found: \(method)"
        }
    }
}

/// An error's message as acpx's runner writes it: `error.message`.
enum TurnFailureText {
    static func message(of error: Error) -> String {
        if let described = error as? LocalizedError, let description = described.errorDescription { return description }
        return String(describing: error)
    }
}

/// The host's scripts on disk, where Node can load them: in a directory of the temporary
/// directory named for what they hold, so a CLI of another version never uses this one's.
enum FlowHostFiles {
    struct Installed {
        let host: String
        let runtime: String
        let sucrase: String
    }

    static func install() throws -> Installed {
        let scripts = [
            ("flow-runtime.mjs", FlowHostScripts.runtime), ("flow-sucrase.mjs", FlowHostScripts.sucrase),
            ("flow-host.mjs", FlowHostScripts.host)
        ]
        let contents = scripts.map(\.1).joined(separator: "\u{0}")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acpx-flow-host-\(FlowRuntimeSupport.shortHash(contents))", isDirectory: true)
        let fm = FileManager.default
        if !scripts.allSatisfy({ fm.fileExists(atPath: directory.appendingPathComponent($0.0).path) }) {
            try fm.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Each written whole under a temporary name, then moved into place: another
            // acpx starting a flow at the same time finds either nothing or the file.
            for (name, text) in scripts {
                let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
                try Data(text.utf8).write(to: temporary)
                _ = rename(temporary.path, directory.appendingPathComponent(name).path)
            }
        }
        return Installed(
            host: directory.appendingPathComponent("flow-host.mjs").path,
            runtime: directory.appendingPathComponent("flow-runtime.mjs").path,
            sucrase: directory.appendingPathComponent("flow-sucrase.mjs").path)
    }
}
