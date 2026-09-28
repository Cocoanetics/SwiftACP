#if os(Windows)
import Foundation
import ucrt
import WinSDK

/// A process started as libuv's `uv_spawn` starts one for Node's `spawn` on Windows: the program
/// found by `search_path`, the command line `make_program_args` builds (as it is for a shim's
/// `cmd.exe`), `make_program_env`'s block, no window (`windowsHide`), and only its three stdio
/// handles inherited. It runs in a job of its own, so that ending the job ends everything the
/// process started (#265, #272).
struct WindowsLaunch {
    let process: HANDLE
    /// Closing it ends whatever is still in it (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`); `nil` when no
    /// job could be made, and only the process is known.
    let job: HANDLE?

    /// Why a start failed: libuv's error for it, as an errno. `ENOENT` when nothing is found.
    struct Failure: Error {
        let code: Int32
    }

    /// `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`, a macro Swift does not import.
    private static let handleListAttribute = DWORD_PTR(0x0002_0002)

    /// Start `spawn` in `cwd`, inheriting `stdio` (its stdin, stdout and stderr) and taking
    /// `environment` (`nil`: this process's), and let it run.
    static func start(
        _ spawn: WindowsSpawnCommand, cwd: String, environment: [String: String]?, stdio: [HANDLE]
    ) throws -> WindowsLaunch {
        let parent = ProcessInfo.processInfo.environment
        let path = environment.flatMap { WindowsSpawnCommand.value(of: "PATH", in: $0) }
            ?? WindowsSpawnCommand.value(of: "PATH", in: parent)
        let searchesCurrentDirectory = "".withCString(encodedAs: UTF16.self) { NeedCurrentDirectoryForExePathW($0) }
        guard let application = LibuvSpawn.searchPath(
            spawn.command, cwd: cwd, path: path, searchesCurrentDirectory: searchesCurrentDirectory,
            isFile: WindowsSpawnCommand.FileSystem.local.isFile)
        else { throw Failure(code: ENOENT) }
        let commandLine = LibuvSpawn.commandLine([spawn.command] + spawn.arguments, verbatim: spawn.verbatimArguments)
        var block = environment.map { LibuvSpawn.environmentBlock($0, parent: parent) }
        let started = try create(
            application: application, commandLine: commandLine, environment: &block, cwd: cwd, stdio: stdio)
        guard let process = started.hProcess, let thread = started.hThread else { throw Failure(code: EINVAL) }
        defer { CloseHandle(thread) }
        let job = makeJob(for: process)
        guard ResumeThread(thread) != DWORD.max else {
            let error = GetLastError()
            if let job {
                TerminateJobObject(job, 1)
                CloseHandle(job)
            } else {
                TerminateProcess(process, 1)
            }
            CloseHandle(process)
            throw Failure(code: errorCode(for: error))
        }
        return WindowsLaunch(process: process, job: job)
    }

    /// `CreateProcessW`, suspended until the process is in its job, inheriting only `stdio`.
    private static func create(
        application: String, commandLine: String, environment: inout [UInt16]?, cwd: String, stdio: [HANDLE]
    ) throws -> PROCESS_INFORMATION {
        var size = SIZE_T(0)
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &size)
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { memory.deallocate() }
        let attributes = LPPROC_THREAD_ATTRIBUTE_LIST(memory)
        guard InitializeProcThreadAttributeList(attributes, 1, 0, &size) else {
            throw Failure(code: errorCode(for: GetLastError()))
        }
        defer { DeleteProcThreadAttributeList(attributes) }
        // The list must outlive the attribute list, so it is not a temporary buffer.
        let inherited = UnsafeMutablePointer<HANDLE?>.allocate(capacity: stdio.count)
        inherited.initialize(from: stdio.map { Optional($0) }, count: stdio.count)
        defer { inherited.deallocate() }
        guard UpdateProcThreadAttribute(
            attributes, 0, handleListAttribute, inherited, SIZE_T(MemoryLayout<HANDLE?>.stride * stdio.count), nil, nil)
        else { throw Failure(code: errorCode(for: GetLastError())) }

        var startup = STARTUPINFOEXW()
        startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        startup.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES) | DWORD(STARTF_USESHOWWINDOW)
        startup.StartupInfo.wShowWindow = WORD(SW_HIDE)
        startup.StartupInfo.hStdInput = stdio[0]
        startup.StartupInfo.hStdOutput = stdio[1]
        startup.StartupInfo.hStdError = stdio[2]
        startup.lpAttributeList = attributes
        // No window, as none of its stdio is the console's (libuv's `windowsHide`).
        let flags = DWORD(CREATE_UNICODE_ENVIRONMENT) | DWORD(EXTENDED_STARTUPINFO_PRESENT)
            | DWORD(CREATE_NO_WINDOW) | DWORD(CREATE_SUSPENDED)
        var information = PROCESS_INFORMATION()
        var line = Array(commandLine.utf16) + [0]
        let created = application.withCString(encodedAs: UTF16.self) { applicationName in
            cwd.withCString(encodedAs: UTF16.self) { directory in
                line.withUnsafeMutableBufferPointer { line in
                    withBlock(&environment) { block in
                        withUnsafeMutablePointer(to: &startup) { startup in
                            CreateProcessW(
                                applicationName, line.baseAddress, nil, nil, true, flags, block, directory,
                                startup.pointer(to: \.StartupInfo), &information)
                        }
                    }
                }
            }
        }
        guard created else { throw Failure(code: errorCode(for: GetLastError())) }
        return information
    }

    private static func withBlock<Result>(
        _ block: inout [UInt16]?, _ body: (UnsafeMutableRawPointer?) -> Result
    ) -> Result {
        guard block != nil else { return body(nil) }
        return block!.withUnsafeMutableBufferPointer { body(UnsafeMutableRawPointer($0.baseAddress)) }
    }

    /// A job for the process, which ends whatever is in it once closed. Without one the process
    /// still runs, but only it is known.
    private static func makeJob(for process: HANDLE) -> HANDLE? {
        guard let job = CreateJobObjectW(nil, nil) else { return nil }
        var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
        let limited = SetInformationJobObject(
            job, JobObjectExtendedLimitInformation, &limits,
            DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size))
        guard limited, AssignProcessToJobObject(job, process) else {
            CloseHandle(job)
            return nil
        }
        return job
    }

    /// libuv's `uv_translate_sys_error` for what starting a process fails with, as an errno.
    static func errorCode(for error: DWORD) -> Int32 {
        switch error {
        case DWORD(ERROR_FILE_NOT_FOUND), DWORD(ERROR_PATH_NOT_FOUND), DWORD(ERROR_DIRECTORY),
             DWORD(ERROR_INVALID_NAME), DWORD(ERROR_BAD_PATHNAME), DWORD(ERROR_INVALID_DRIVE),
             DWORD(ERROR_MOD_NOT_FOUND):
            return ENOENT
        case DWORD(ERROR_ACCESS_DENIED): return EPERM
        case DWORD(ERROR_ELEVATION_REQUIRED): return EACCES
        case DWORD(ERROR_NOT_ENOUGH_MEMORY), DWORD(ERROR_OUTOFMEMORY): return ENOMEM
        default: return EINVAL
        }
    }

    // MARK: - Handles

    /// Handles a start takes for stdio, inherited while they are open.
    static func inheritable() -> SECURITY_ATTRIBUTES {
        SECURITY_ATTRIBUTES(
            nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: nil, bInheritHandle: true)
    }

    /// `NUL`, for a stdin libuv's `ignore` gives.
    static func openNull(_ security: inout SECURITY_ATTRIBUTES) -> HANDLE? {
        let handle = "NUL".withCString(encodedAs: UTF16.self) {
            CreateFileW(
                $0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), &security, DWORD(OPEN_EXISTING),
                0, nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
        return handle
    }

    /// An anonymous pipe: the end `childReads` says the process inherits, the other kept here.
    static func makePipe(
        _ security: inout SECURITY_ATTRIBUTES, childReads: Bool = false
    ) -> (read: HANDLE, write: HANDLE)? {
        var read: HANDLE?
        var write: HANDLE?
        guard CreatePipe(&read, &write, &security, 0), let read, let write else { return nil }
        SetHandleInformation(childReads ? write : read, DWORD(HANDLE_FLAG_INHERIT), 0)
        return (read, write)
    }
}
#endif
