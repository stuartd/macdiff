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

@Test func lastCommitReadsCommittedVersionsAndIgnoresWorkingTreeAndIndex() throws {
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
    let snapshot = try GitRepository.scan(fixture.root)
    #expect(snapshot.commit?.subject == "Fixture")
    #expect(snapshot.commit?.parents.count == 1)
    #expect(snapshot.changes.map(\.path) == [":(glob)*[x]?.txt", "deleted", "edited", "new\t日本語\n.txt"])
    let edited = try #require(snapshot.changes.first { $0.path == "edited" })
    let pair = try GitRepository.comparison(for: edited, in: snapshot)
    #expect(pair.original == "before" && pair.changed == "committed")
    let added = try GitRepository.comparison(for: #require(snapshot.changes.first { $0.status == "Added" }), in: snapshot)
    #expect(added.original.isEmpty && added.changed == "added")
    let deleted = try GitRepository.comparison(for: #require(snapshot.changes.first { $0.status == "Deleted" }), in: snapshot)
    #expect(deleted.original == "removed content" && deleted.changed.isEmpty)
    let rename = try #require(snapshot.changes.first { $0.status == "Renamed" })
    #expect(rename.originalPath == "old\t日本語\n.txt")
    let renamed = try GitRepository.comparison(for: rename, in: snapshot)
    #expect(renamed.original == "rename content" && renamed.changed == "rename content")
    #expect(try Data(contentsOf: index) == before)
    try fixture.commit()
    #expect(try GitRepository.comparison(for: edited, in: snapshot).changed == "committed")
}

@Test func lastCommitSupportsUnbornInitialEmptyAndDetachedCommits() throws {
    let fixture = try RepositoryFixture()
    try fixture.write("first", "first contents")
    let unborn = try GitRepository.scan(fixture.root)
    #expect(unborn.commit == nil && unborn.changes.isEmpty)
    try fixture.commit()
    let initial = try GitRepository.scan(fixture.root)
    #expect(initial.commit?.parents.isEmpty == true)
    let pair = try GitRepository.comparison(for: #require(initial.changes.first), in: initial)
    #expect(pair.original.isEmpty && pair.changed == "first contents")
    try fixture.git("commit", "--allow-empty", "-m", "Empty commit")
    try fixture.git("checkout", "--detach")
    let empty = try GitRepository.scan(fixture.root)
    #expect(empty.branch == "Detached HEAD")
    #expect(empty.commit?.subject == "Empty commit" && empty.changes.isEmpty)
}

@Test func lastMergeCommitShowsFirstParentChanges() throws {
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
    let snapshot = try GitRepository.scan(fixture.root)
    #expect(snapshot.commit?.parents.count == 2)
    #expect(snapshot.commit?.parents.first == parent)
    #expect(snapshot.changes.map(\.path) == ["feature"])
    let pair = try GitRepository.comparison(for: #require(snapshot.changes.first), in: snapshot)
    #expect(pair.original.isEmpty && pair.changed == "merged feature")
}

@Test func committedUnsupportedFilesStayListedWithoutReadingWorkingCopies() throws {
    let fixture = try RepositoryFixture()
    try Data([0, 1, 2]).write(to: fixture.root.appendingPathComponent("binary"))
    try fixture.write("large", String(repeating: "x", count: TextFileReader.maximumByteCount + 1))
    try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("link").path, withDestinationPath: "binary")
    try fixture.commit()
    let snapshot = try GitRepository.scan(fixture.root)
    #expect(snapshot.changes.count == 3)
    for change in snapshot.changes {
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(change.path))
        try fixture.write(change.path, "readable working copy")
        #expect(throws: (any Error).self) { try GitRepository.comparison(for: change, in: snapshot) }
    }
}

@Test func historySearchAndOldCommitSelectionUseImmutableObjects() throws {
    let fixture = try RepositoryFixture()
    try fixture.write("file", "first")
    try fixture.commit()
    let first = try #require(GitRepository.scan(fixture.root).commit)
    try fixture.write("file", "second")
    try fixture.git("add", "--all")
    try fixture.git("commit", "-m", "Needle [literal]", "-m", "Searchable body")
    let second = try #require(GitRepository.scan(fixture.root).commit)
    try fixture.write("file", "third")
    try fixture.commit()
    let latest = try GitRepository.scan(fixture.root)
    let history = try GitRepository.history(in: latest)
    #expect(history.map(\.id) == [latest.head!, second.id, first.id])
    #expect(try GitRepository.history(in: latest, limit: 1).count == 1)
    #expect(try GitRepository.history(in: latest, query: "NEEDLE [literal]").map(\.id) == [second.id])
    #expect(try GitRepository.history(in: latest, query: "searchable body").map(\.id) == [second.id])
    #expect(try GitRepository.history(in: latest, query: second.shortID).map(\.id) == [second.id])
    #expect(try GitRepository.history(in: latest, query: "no match").isEmpty)
    let old = try GitRepository.scan(fixture.root, commitID: second.id)
    try fixture.write("file", "staged")
    try fixture.git("add", "file")
    try fixture.write("file", "local")
    let index = try Data(contentsOf: fixture.root.appendingPathComponent(".git/index"))
    let pair = try GitRepository.comparison(for: #require(old.changes.first), in: old)
    #expect(pair.original == "first" && pair.changed == "second")
    #expect(try Data(contentsOf: fixture.root.appendingPathComponent(".git/index")) == index)
    #expect(throws: (any Error).self) { try GitRepository.scan(fixture.root, commitID: "--all") }
    #expect(throws: (any Error).self) { try GitRepository.scan(fixture.root, commitID: String(repeating: "0", count: 40)) }
    try fixture.git("checkout", "--detach")
    #expect(try GitRepository.scan(fixture.root).branch == "Detached HEAD")
    let worktree = fixture.root.appendingPathComponent("linked")
    try fixture.git("worktree", "add", "--detach", worktree.path)
    #expect(try GitRepository.scan(worktree, commitID: first.id).commit?.id == first.id)
}

@Test func unbornRepositoryIgnoresStagedFilesAndHasNoHistory() throws {
    let fixture = try RepositoryFixture()
    try fixture.write("file", "staged")
    try fixture.git("add", "file")
    let snapshot = try GitRepository.scan(fixture.root)
    #expect(snapshot.commit == nil && snapshot.changes.isEmpty)
    #expect(try GitRepository.history(in: snapshot).isEmpty)
}
