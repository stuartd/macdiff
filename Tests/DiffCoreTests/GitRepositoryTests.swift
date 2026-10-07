import Foundation
import Testing
@testable import DiffCore

private final class RepositoryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("macdiff-repo-\(UUID())", isDirectory: true)
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-b", "main")
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult func git(_ arguments: String...) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = root
        process.arguments = ["-c", "user.name=MacDiff Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "GitFixture", code: Int(process.terminationStatus)) }
        return data
    }
    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func commit() throws {
        try git("add", "--all")
        try git("commit", "-m", "Fixture")
    }
}

@Test(arguments: [false, true])
func fileDirectoryReplacementsCompareAddedAndDeletedSides(reverse: Bool) async throws {
    let fixture = try RepositoryFixture()
    let originalPath = reverse ? "item/child" : "item"
    let changedPath = reverse ? "item" : "item/child"
    try fixture.write(originalPath, "original file contents")
    try fixture.commit()
    try fixture.git("rm", originalPath)
    try fixture.write(changedPath, "completely unrelated new text")
    try fixture.commit()
    let snapshot = try await GitRepository.scan(fixture.root)
    #expect(snapshot.changes.count == 2)
    let removed = try #require(snapshot.changes.first { $0.changeStatus == "D" })
    let added = try #require(snapshot.changes.first { $0.changeStatus == "A" })
    let before = try await GitRepository.comparison(for: removed, in: snapshot)
    let after = try await GitRepository.comparison(for: added, in: snapshot)
    #expect(before.original == "original file contents" && before.changed.isEmpty)
    #expect(after.original.isEmpty && after.changed == "completely unrelated new text")
}

@Test func commitLabelsIdentifyRootOrdinaryAndMergeBaselines() {
    let root = GitCommit(id: "abcdef012345", subject: "Root", parents: [])
    let ordinary = GitCommit(id: "abcdef012345", subject: "Next", parents: ["123456789abc"])
    let merge = GitCommit(id: "abcdef012345", subject: "Merge", parents: ["123456789abc", "987654321fed"])
    #expect(root.baselineLabel == "Before · Empty tree")
    #expect(ordinary.baselineLabel == "Before · 1234567")
    #expect(merge.baselineLabel == "Before · 1234567 (first parent)")
    for commit in [root, ordinary, merge] { #expect(commit.targetLabel == "After · abcdef0") }
}

@Test func lastCommitReadsCommittedVersionsAndIgnoresWorkingTreeAndIndex() async throws {
    let fixture = try RepositoryFixture()
    try fixture.write("edited", "before")
    try fixture.write("deleted", "removed content")
    try fixture.write("old\t日本語\n.txt", "rename content")
    try fixture.commit()
    try fixture.write("edited", "committed")
    try fixture.write(":(glob)*[x]?.txt", "added")
    try fixture.git("rm", "deleted")
    try fixture.git("mv", "old\t日本語\n.txt", "new\t日本語\n.txt")
    try fixture.commit()
    try fixture.write("edited", "staged later")
    try fixture.git("add", "edited")
    try fixture.write("edited", "unstaged later")
    try fixture.write("untracked", "not in commit")
    try fixture.write("deleted", "recreated later")
    let index = fixture.root.appendingPathComponent(".git/index")
    let before = try Data(contentsOf: index)
    let snapshot = try await GitRepository.scan(fixture.root)
    #expect(snapshot.commit?.subject == "Fixture")
    #expect(snapshot.commit?.parents.count == 1)
    #expect(snapshot.changes.map(\.path) == [":(glob)*[x]?.txt", "deleted", "edited", "new\t日本語\n.txt"])
    let edited = try #require(snapshot.changes.first { $0.path == "edited" })
    let pair = try await GitRepository.comparison(for: edited, in: snapshot)
    #expect(pair.original == "before" && pair.changed == "committed")
    let added = try await GitRepository.comparison(for: #require(snapshot.changes.first { $0.status == "Added" }), in: snapshot)
    #expect(added.original.isEmpty && added.changed == "added")
    let deleted = try await GitRepository.comparison(for: #require(snapshot.changes.first { $0.status == "Deleted" }), in: snapshot)
    #expect(deleted.original == "removed content" && deleted.changed.isEmpty)
    let rename = try #require(snapshot.changes.first { $0.status == "Renamed" })
    #expect(rename.originalPath == "old\t日本語\n.txt")
    let renamed = try await GitRepository.comparison(for: rename, in: snapshot)
    #expect(renamed.original == "rename content" && renamed.changed == "rename content")
    #expect(try Data(contentsOf: index) == before)
    try fixture.commit()
    #expect(try await GitRepository.comparison(for: edited, in: snapshot).changed == "committed")
}

@Test func lastCommitSupportsUnbornInitialEmptyAndDetachedCommits() async throws {
    let fixture = try RepositoryFixture()
    try fixture.write("first", "first contents")
    let unborn = try await GitRepository.scan(fixture.root)
    #expect(unborn.commit == nil && unborn.changes.isEmpty)
    try fixture.commit()
    let initial = try await GitRepository.scan(fixture.root)
    #expect(initial.commit?.parents.isEmpty == true)
    let pair = try await GitRepository.comparison(for: #require(initial.changes.first), in: initial)
    #expect(pair.original.isEmpty && pair.changed == "first contents")
    try fixture.git("commit", "--allow-empty", "-m", "Empty commit")
    try fixture.git("checkout", "--detach")
    let empty = try await GitRepository.scan(fixture.root)
    #expect(empty.branch == "Detached HEAD")
    #expect(empty.commit?.subject == "Empty commit" && empty.changes.isEmpty)
}

@Test func lastMergeCommitShowsFirstParentChanges() async throws {
    let fixture = try RepositoryFixture()
    try fixture.write("base", "base")
    try fixture.commit()
    try fixture.git("checkout", "-b", "feature")
    try fixture.write("feature", "merged feature")
    try fixture.commit()
    try fixture.git("checkout", "main")
    try fixture.write("main", "main change")
    try fixture.commit()
    let parent = String(decoding: try fixture.git("rev-parse", "HEAD"), as: UTF8.self).trimmingCharacters(in: .newlines)
    try fixture.git("merge", "--no-ff", "feature", "-m", "Merge feature")
    let snapshot = try await GitRepository.scan(fixture.root)
    #expect(snapshot.commit?.parents.count == 2)
    #expect(snapshot.commit?.parents.first == parent)
    #expect(snapshot.changes.map(\.path) == ["feature"])
    let pair = try await GitRepository.comparison(for: #require(snapshot.changes.first), in: snapshot)
    #expect(pair.original.isEmpty && pair.changed == "merged feature")
}

@Test func committedUnsupportedFilesStayListedWithoutReadingWorkingCopies() async throws {
    let fixture = try RepositoryFixture()
    try Data([0, 1, 2]).write(to: fixture.root.appendingPathComponent("binary"))
    try fixture.write("large", String(repeating: "x", count: TextFileReader.maximumByteCount + 1))
    try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("link").path, withDestinationPath: "binary")
    try fixture.commit()
    let snapshot = try await GitRepository.scan(fixture.root)
    #expect(snapshot.changes.count == 3)
    for change in snapshot.changes {
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(change.path))
        try fixture.write(change.path, "readable working copy")
        await #expect(throws: (any Error).self) { try await GitRepository.comparison(for: change, in: snapshot) }
    }
}

@Test func historySearchAndOldCommitSelectionUseImmutableObjects() async throws {
    let fixture = try RepositoryFixture()
    try fixture.write("file", "first")
    try fixture.commit()
    let first = try #require(await GitRepository.scan(fixture.root).commit)
    try fixture.write("file", "second")
    try fixture.git("add", "--all")
    try fixture.git("commit", "-m", "Needle [literal]", "-m", "Searchable body")
    let second = try #require(await GitRepository.scan(fixture.root).commit)
    try fixture.write("file", "third")
    try fixture.commit()
    let latest = try await GitRepository.scan(fixture.root)
    let history = try await GitRepository.history(in: latest)
    #expect(history.map(\.id) == [latest.head!, second.id, first.id])
    #expect(try await GitRepository.history(in: latest, limit: 1).count == 1)
    #expect(try await GitRepository.history(in: latest, query: "NEEDLE [literal]").map(\.id) == [second.id])
    #expect(try await GitRepository.history(in: latest, query: "searchable body").map(\.id) == [second.id])
    #expect(try await GitRepository.history(in: latest, query: second.shortID).map(\.id) == [second.id])
    #expect(try await GitRepository.history(in: latest, query: "no match").isEmpty)
    let old = try await GitRepository.scan(fixture.root, commitID: second.id)
    try fixture.write("file", "staged")
    try fixture.git("add", "file")
    try fixture.write("file", "local")
    let index = try Data(contentsOf: fixture.root.appendingPathComponent(".git/index"))
    let pair = try await GitRepository.comparison(for: #require(old.changes.first), in: old)
    #expect(pair.original == "first" && pair.changed == "second")
    #expect(try Data(contentsOf: fixture.root.appendingPathComponent(".git/index")) == index)
    await #expect(throws: (any Error).self) { try await GitRepository.scan(fixture.root, commitID: "--all") }
    await #expect(throws: (any Error).self) { try await GitRepository.scan(fixture.root, commitID: String(repeating: "0", count: 40)) }
    try fixture.git("checkout", "--detach")
    #expect(try await GitRepository.scan(fixture.root).branch == "Detached HEAD")
    let worktree = fixture.root.appendingPathComponent("linked")
    try fixture.git("worktree", "add", "--detach", worktree.path)
    #expect(try await GitRepository.scan(worktree, commitID: first.id).commit?.id == first.id)
}

@Test func unbornRepositoryIgnoresStagedFilesAndHasNoHistory() async throws {
    let fixture = try RepositoryFixture()
    try fixture.write("file", "staged")
    try fixture.git("add", "file")
    let snapshot = try await GitRepository.scan(fixture.root)
    #expect(snapshot.commit == nil && snapshot.changes.isEmpty)
    #expect(try await GitRepository.history(in: snapshot).isEmpty)
}
