import ACPXCore
import Foundation

// skill-install's work on the file system, with what fails said as Node says it: the bundle
// unpacked in a temporary directory and copied from there, as `installSkill` does.
extension SkillInstall {
    /// `installSkill` for `target`: the skill's bundle unpacked in a directory of its own under the
    /// temporary directory, its name read from its `SKILL.md`, and the skill copied under that name
    /// to where the agent keeps its skills in the scope — over what is there, with `force`.
    /// Returns the name and where the skill went.
    static func install(
        _ target: Target, force: Bool, context: Skillflag.Context
    ) throws -> (skill: String, path: String) {
        let cwd = context.cwd
        let temporary = try makeTemporaryDirectory(
            prefix: NodePath.joined(temporaryRoot(context.environment), "skill-install-"), cwd: cwd)
        defer { try? FileManager.default.removeItem(atPath: located(temporary, in: cwd)) }
        // `extractSkillTarToTemp`: the bundle's one directory, named as the skill was given.
        let unpacked = NodePath.joined(temporary, target.skill)
        try makeDirectories(unpacked, cwd: cwd)
        try write(Data(BundledSkill.markdown.utf8), to: NodePath.joined(unpacked, "SKILL.md"), cwd: cwd)
        // `readSkillMetadata`.
        guard let name = SkillBundle.frontmatter["name"] else { throw Failure("SKILL.md metadata is missing name.") }
        guard SkillBundle.frontmatter["description"] != nil else {
            throw Failure("SKILL.md metadata is missing description.")
        }
        let root = try skillsRoot(agent: target.agent, scope: target.scope, context: context)
        let destination = NodePath.joined(root, name)
        // `copySkillDir`.
        if access(located(destination, in: cwd), F_OK) == 0 {
            guard force else { throw Failure("Destination already exists: \(destination)") }
            try remove(destination, cwd: cwd)
        }
        try makeDirectories(NodePath.dirname(destination), cwd: cwd)
        try copyDirectory(unpacked, to: destination, cwd: cwd)
        return (name, destination)
    }

    /// Where `path` is for a system call: itself when absolute, else under `cwd`.
    static func located(_ path: String, in cwd: String) -> String {
        path.hasPrefix("/") ? path : cwd + "/" + path
    }

    /// Node's `os.tmpdir()`: `TMPDIR`, `TMP` or `TEMP` — the first not empty — else `/tmp`, without
    /// a trailing `/`.
    static func temporaryRoot(_ environment: [String: String]) -> String {
        let root = ["TMPDIR", "TMP", "TEMP"].lazy.compactMap { environment[$0] }.first { !$0.isEmpty } ?? "/tmp"
        return root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
    }

    /// `fs.mkdtemp(prefix)`: a new directory named `prefix` and six random characters.
    static func makeTemporaryDirectory(prefix: String, cwd: String) throws -> String {
        var template = Array(located(prefix + "XXXXXX", in: cwd).utf8CString)
        let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) != nil }
        let tried = prefix + String(decoding: template.dropLast().suffix(6).map(UInt8.init), as: UTF8.self)
        guard made else { throw Failure(NodePath.errorMessage(errno, syscall: "mkdtemp", path: tried)) }
        return tried
    }

    /// Node's `fs.mkdir(path, { recursive: true })` (`MKDirpAsync`): each directory missing made from
    /// the top down. It fails at the directory it was making — with an error of its `stat` for an
    /// error of its own it does not know — and stops without one where that `stat` finds a directory.
    static func makeDirectories(_ path: String, cwd: String) throws {
        func failure(_ code: Int32, _ path: String) -> Failure {
            Failure(NodePath.errorMessage(code, syscall: "mkdir", path: path))
        }
        var pending = [path]
        while let next = pending.popLast() {
            var error = mkdir(located(next, in: cwd), 0o777) == 0 ? 0 : errno
            while true {
                switch error {
                case 0:
                    break
                case EACCES, ENOSPC, ENOTDIR, EPERM:
                    throw failure(error, next)
                case ENOENT:
                    let parent = next.lastIndex(of: "/").map { String(next[..<$0]) } ?? next
                    if parent != next {
                        pending += [next, parent]
                    } else if pending.isEmpty {
                        error = EEXIST
                        continue
                    }
                default:
                    var status = stat()
                    let looked = stat(located(next, in: cwd), &status) == 0 ? 0 : errno
                    let isDirectory = looked == 0 && status.st_mode & S_IFMT == S_IFDIR
                    if error == EEXIST, !pending.isEmpty {
                        guard isDirectory else { throw failure(ENOTDIR, next) }
                        break
                    }
                    let failed = looked != 0 ? looked : isDirectory ? 0 : EEXIST
                    guard failed == 0 else { throw failure(failed, next) }
                    return
                }
                break
            }
        }
    }

    /// `fs.writeFile(path, data)`.
    static func write(_ data: Data, to path: String, cwd: String) throws {
        let descriptor = open(located(path, in: cwd), O_WRONLY | O_CREAT | O_TRUNC, 0o666)
        guard descriptor >= 0 else { throw Failure(NodePath.errorMessage(errno, syscall: "open", path: path)) }
        defer { close(descriptor) }
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { bytes in
                Foundation.write(descriptor, bytes.baseAddress! + written, data.count - written)
            }
            guard count >= 0 else { throw Failure(NodePath.errorMessage(errno, syscall: "write")) }
            written += count
        }
    }

    /// `fs.rm(path, { recursive: true, force: true })`: a file, or a directory with what it holds.
    static func remove(_ path: String, cwd: String) throws {
        do {
            try FileManager.default.removeItem(atPath: located(path, in: cwd))
        } catch let error as NSError {
            let code = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? Int(EIO)
            guard code != ENOENT else { return }
            throw Failure(NodePath.errorMessage(Int32(code), syscall: "rm", path: path))
        }
    }

    /// `fs.cp(source, destination, { recursive: true })`: the directory made, and what it holds
    /// copied into it, each with the mode its own has.
    static func copyDirectory(_ source: String, to destination: String, cwd: String) throws {
        guard mkdir(located(destination, in: cwd), 0o777) == 0 else {
            throw Failure(NodePath.errorMessage(errno, syscall: "mkdir", path: destination))
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: located(source, in: cwd))) ?? []
        for name in names.sorted() {
            let (from, to) = (NodePath.joined(source, name), NodePath.joined(destination, name))
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: located(from, in: cwd), isDirectory: &isDirectory)
            if isDirectory.boolValue {
                try copyDirectory(from, to: to, cwd: cwd)
            } else {
                guard let data = FileManager.default.contents(atPath: located(from, in: cwd)) else {
                    throw Failure(NodePath.errorMessage(errno, syscall: "copyfile", path: from))
                }
                try write(data, to: to, cwd: cwd)
            }
        }
    }
}
