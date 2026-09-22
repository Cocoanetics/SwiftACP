@testable import ACPXCore
import Foundation
import Testing

/// Repository-boundary scoping for the session directory walk. A git worktree or
/// submodule marks its root with a `.git` *file* — a `gitdir:` pointer — rather than a
/// directory, and a directory whose own name begins with two dots is still inside its
/// boundary. Ports acpx 0.19.1's `hasGitMarker` / `isWithinBoundary` (issue #22).
///
/// Serialized because the store cases redirect the process-wide ``ACPXPaths/baseDir``.
@Suite(.serialized) struct SessionScopeTests {
    // MARK: Fixtures

    /// A fresh temp tree, symlink-resolved so its paths compare equal to the ones the
    /// walk derives (macOS hands out `/var/folders/…`, a link to `/private/var/…`).
    private func makeTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acpx-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    @discardableResult
    private func makeDir(_ url: URL) throws -> String {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// The `.git` a worktree or submodule gets: a file pointing at the real git dir.
    private func writeGitPointerFile(in dir: URL) throws {
        try "gitdir: /elsewhere/.git/worktrees/wt\n"
            .write(to: dir.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    }

    private func seedSession(agent: String, cwd: String, id: String) throws {
        let now = nowISO()
        var record = SessionRecord(
            acpxRecordId: id, acpSessionId: id, agentCommand: agent,
            cwd: SessionStore.absolute(cwd), createdAt: now, lastUsedAt: now)
        record.closed = false
        try SessionStore.writeRecord(record)
    }

    // MARK: Boundary detection

    @Test func worktreePointerFileMarksTheRepositoryRoot() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree) }
        let worktree = tree.appendingPathComponent("wt", isDirectory: true)
        let sub = try makeDir(worktree.appendingPathComponent("src/feature", isDirectory: true))
        try writeGitPointerFile(in: worktree)

        #expect(SessionStore.findGitRepositoryRoot(sub) == worktree.path)
    }

    @Test func ordinaryCloneStillMarksTheRepositoryRoot() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree) }
        let repo = tree.appendingPathComponent("repo", isDirectory: true)
        let sub = try makeDir(repo.appendingPathComponent("src", isDirectory: true))
        try makeDir(repo.appendingPathComponent(".git", isDirectory: true))

        #expect(SessionStore.findGitRepositoryRoot(sub) == repo.path)
    }

    // MARK: Walk scoping

    @Test func sessionAtAWorktreeRootIsFoundFromASubdirectory() async throws {
        try await withIsolatedStore {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree) }
            let worktree = tree.appendingPathComponent("wt", isDirectory: true)
            let sub = try makeDir(worktree.appendingPathComponent("src", isDirectory: true))
            try writeGitPointerFile(in: worktree)
            try seedSession(agent: "claude", cwd: worktree.path, id: "wt-1")

            let found = SessionStore.findSessionByDirectoryWalk(
                agentCommand: "claude", cwd: sub, name: nil,
                boundary: SessionStore.findGitRepositoryRoot(sub))
            #expect(found?.acpxRecordId == "wt-1")
        }
    }

    @Test func aSiblingWorktreeDoesNotReuseTheSession() async throws {
        try await withIsolatedStore {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree) }
            let first = tree.appendingPathComponent("wt-a", isDirectory: true)
            try makeDir(first)
            try writeGitPointerFile(in: first)
            try seedSession(agent: "claude", cwd: first.path, id: "wt-a-1")

            let second = tree.appendingPathComponent("wt-b", isDirectory: true)
            let sub = try makeDir(second.appendingPathComponent("src", isDirectory: true))
            try writeGitPointerFile(in: second)

            let found = SessionStore.findSessionByDirectoryWalk(
                agentCommand: "claude", cwd: sub, name: nil,
                boundary: SessionStore.findGitRepositoryRoot(sub))
            #expect(found == nil)
        }
    }

    @Test func directoryNamedWithTwoDotsStaysInsideTheBoundary() async throws {
        try await withIsolatedStore {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree) }
            let repo = tree.appendingPathComponent("repo", isDirectory: true)
            try makeDir(repo.appendingPathComponent(".git", isDirectory: true))
            let dotted = repo.appendingPathComponent("..cache", isDirectory: true)
            let sub = try makeDir(dotted.appendingPathComponent("pkg", isDirectory: true))
            try seedSession(agent: "claude", cwd: dotted.path, id: "dots-1")

            let found = SessionStore.findSessionByDirectoryWalk(
                agentCommand: "claude", cwd: sub, name: nil,
                boundary: SessionStore.findGitRepositoryRoot(sub))
            #expect(found?.acpxRecordId == "dots-1")
        }
    }
}
