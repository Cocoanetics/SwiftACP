#if os(Windows)
import Foundation
import WinSDK

/// ``ChildProcess``'s reader on Windows: stdout and stderr, overlapped named pipes, read on one
/// thread that also waits for the process. What the process wrote before it exited is read before
/// its exit is reported, the order the POSIX reader and waiter keep (#272).
final class WindowsPipeReader {
    /// `WAIT_OBJECT_0`, a cast Swift does not import: what a wait answers for a signalled object.
    static let signalled: DWORD = 0

    private let pipes: [OverlappedPipe]
    private let process: HANDLE
    private let wake: HANDLE
    private let onChunk: @Sendable (ChildProcess.Output, [UInt8]) -> Void
    private let onClose: @Sendable (ChildProcess.Output) -> Void
    private let isStopped: () -> Bool

    init(
        outputs: [HANDLE], events: [HANDLE], process: HANDLE, wake: HANDLE,
        onChunk: @escaping @Sendable (ChildProcess.Output, [UInt8]) -> Void,
        onClose: @escaping @Sendable (ChildProcess.Output) -> Void, isStopped: @escaping () -> Bool
    ) {
        pipes = zip(zip(outputs, events), [ChildProcess.Output.stdout, .stderr]).map {
            OverlappedPipe(handle: $0.0, event: $0.1, output: $1)
        }
        self.process = process
        self.wake = wake
        self.onChunk = onChunk
        self.onClose = onClose
        self.isStopped = isStopped
    }

    /// Read until the process exits, then what the pipes hold at that moment: `true`. `false` when
    /// stopped first.
    func run() -> Bool {
        pipes.forEach(pump)
        while !isStopped() {
            var handles: [HANDLE?] = [wake, process] + pipes.filter(\.isOpen).map { Optional($0.event) }
            guard WaitForMultipleObjects(DWORD(handles.count), &handles, false, INFINITE) != DWORD.max else {
                return false
            }
            guard !isStopped() else { return false }
            serviceReadyPipes()
            if WaitForSingleObject(process, 0) == Self.signalled {
                pipes.filter(\.isOpen).forEach(drain)
                return true
            }
        }
        return false
    }

    /// Once the exit is reported, read on until both pipes close, or reading is stopped.
    func finish() {
        pipes.forEach(pump)
        while pipes.contains(where: \.isOpen), !isStopped() {
            var handles: [HANDLE?] = [wake] + pipes.filter(\.isOpen).map { Optional($0.event) }
            guard WaitForMultipleObjects(DWORD(handles.count), &handles, false, INFINITE) != DWORD.max,
                  !isStopped()
            else { return }
            serviceReadyPipes()
        }
    }

    /// Let go of the pipes: a read under way cancelled and waited for first.
    func release() {
        pipes.forEach { $0.release() }
    }

    /// Each open pipe whose read is done, taken in and read on: every one that is ready, as the
    /// POSIX reader takes each pipe `poll` finds ready, rather than only the first a wait answers.
    private func serviceReadyPipes() {
        for pipe in pipes where pipe.isOpen && WaitForSingleObject(pipe.event, 0) == Self.signalled {
            if pipe.isPending { deliver(pipe.harvest(), from: pipe) }
            pump(pipe)
        }
    }

    /// Reads on `pipe` until one waits: at most 16, as the POSIX reader bounds its reads per look,
    /// so a writer that never stops cannot keep the thread from the process and the wake. Past the
    /// bound, the pipe's event is set so the next look comes back to it.
    private func pump(_ pipe: OverlappedPipe) {
        for _ in 0..<16 {
            guard pipe.isOpen, !pipe.isPending else { return }
            let outcome = pipe.begin(limit: Int.max)
            deliver(outcome, from: pipe)
            if case .pending = outcome { return }
        }
        if pipe.isOpen, !pipe.isPending { SetEvent(pipe.event) }
    }

    /// What `pipe` holds as the process exits, all it wrote before then, and no more: a background
    /// child may never stop writing. The exit's signal does not order a read under way, whose
    /// completion may not have reached this thread yet: it is settled first, taking what it got, or
    /// cancelled if nothing came (#278 review).
    private func drain(_ pipe: OverlappedPipe) {
        if pipe.isPending { deliver(pipe.settle(), from: pipe) }
        var remaining = pipe.available()
        while remaining > 0, pipe.isOpen {
            var outcome = pipe.begin(limit: remaining)
            // The bytes are there, so a read that waits is done at once.
            if case .pending = outcome { outcome = pipe.harvest(waiting: true) }
            if case .data(let bytes) = outcome { remaining -= max(bytes.count, 1) }
            deliver(outcome, from: pipe)
        }
    }

    private func deliver(_ outcome: OverlappedPipe.Outcome, from pipe: OverlappedPipe) {
        switch outcome {
        case .data(let bytes):
            if !bytes.isEmpty { onChunk(pipe.output, bytes) }
        case .pending:
            break
        case .end:
            pipe.close()
            onClose(pipe.output)
        }
    }
}

/// One output pipe's overlapped reads, one under way at a time, into memory that stays put while
/// the system writes to it.
private final class OverlappedPipe {
    enum Outcome {
        case data([UInt8])
        case pending
        case end
    }

    let output: ChildProcess.Output
    /// Set when a read is done (the `OVERLAPPED`'s event, manual-reset).
    let event: HANDLE
    private let handle: HANDLE
    private let overlapped = UnsafeMutablePointer<OVERLAPPED>.allocate(capacity: 1)
    private let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 16)
    private(set) var isOpen = true
    private(set) var isPending = false

    init(handle: HANDLE, event: HANDLE, output: ChildProcess.Output) {
        self.handle = handle
        self.event = event
        self.output = output
        overlapped.initialize(to: OVERLAPPED())
    }

    /// Start a read of at most `limit` bytes: the bytes if it is done at once, `.pending` if it
    /// waits, `.end` at the pipe's end.
    func begin(limit: Int) -> Outcome {
        overlapped.pointee = OVERLAPPED()
        overlapped.pointee.hEvent = event
        if ReadFile(handle, buffer.baseAddress, DWORD(min(buffer.count, limit)), nil, overlapped) {
            return result(waiting: false)
        }
        guard GetLastError() == DWORD(ERROR_IO_PENDING) else { return .end }
        isPending = true
        return .pending
    }

    /// The read under way, once its event is set, or `waiting` for it.
    func harvest(waiting: Bool = false) -> Outcome {
        isPending = false
        return result(waiting: waiting)
    }

    /// The read under way, done now: cancelled and waited for. What it had already got, it keeps,
    /// as a read that is complete cannot be cancelled; one that got nothing gives nothing.
    func settle() -> Outcome {
        CancelIoEx(handle, overlapped)
        isPending = false
        return result(waiting: true)
    }

    private func result(waiting: Bool) -> Outcome {
        var count: DWORD = 0
        guard GetOverlappedResult(handle, overlapped, &count, waiting) else {
            // Cancelled, it got nothing; otherwise it failed at the pipe's end (`ERROR_BROKEN_PIPE`).
            return GetLastError() == DWORD(ERROR_OPERATION_ABORTED) ? .data([]) : .end
        }
        return .data(Array(UnsafeRawBufferPointer(rebasing: buffer[0..<Int(count)])))
    }

    /// How many bytes the pipe holds now.
    func available() -> Int {
        var bytes: DWORD = 0
        guard PeekNamedPipe(handle, nil, 0, nil, &bytes, nil) else { return 0 }
        return Int(bytes)
    }

    func close() {
        isOpen = false
    }

    func release() {
        if isPending {
            CancelIoEx(handle, overlapped)
            var count: DWORD = 0
            _ = GetOverlappedResult(handle, overlapped, &count, true)
            isPending = false
        }
        CloseHandle(handle)
        CloseHandle(event)
        overlapped.deallocate()
        buffer.deallocate()
    }
}
#endif
