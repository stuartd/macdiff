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

@Test func repositoryReadsCombinedWorkingChangesWithoutChangingIndex() throws {
    let fixture = try RepositoryFixture()
    try fixture.write("nested/file.txt", "committed\n")
    try fixture.write("deleted.txt", "deleted content\n")
    try fixture.write(".gitignore", "ignored/\n")
    try fixture.commit()
    try fixture.write("nested/file.txt", "staged\n")
    try fixture.git("add", "nested/file.txt")
    try fixture.write("nested/file.txt", "working\n")
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("deleted.txt"))
    try fixture.write("new/deep.txt", "untracked\n")
    try fixture.write("ignored/hidden.txt", "hidden")
    let index = fixture.root.appendingPathComponent(".git/index")
    let before = try Data(contentsOf: index)
    let snapshot = try GitRepository.scan(fixture.root.appendingPathComponent("nested"))
    #expect(snapshot.root.resolvingSymlinksInPath() == fixture.root.resolvingSymlinksInPath())
    #expect(snapshot.branch == "main")
    #expect(snapshot.changes.map(\.path) == ["deleted.txt", "nested/file.txt", "new/deep.txt"])
    let modified = try #require(snapshot.changes.first { $0.path == "nested/file.txt" })
    #expect(modified.stagingDescription == "Staged and unstaged changes")
    let pair = try GitRepository.comparison(for: modified, in: snapshot)
    #expect(pair.original == "committed\n")
    #expect(pair.changed == "working\n")
    let deleted = try GitRepository.comparison(for: #require(snapshot.changes.first { $0.path == "deleted.txt" }), in: snapshot)
    #expect(deleted.original == "deleted content\n" && deleted.changed == "")
    let untracked = try GitRepository.comparison(for: #require(snapshot.changes.first { $0.isUntracked }), in: snapshot)
    #expect(untracked.original == "" && untracked.changed == "untracked\n")
    #expect(try Data(contentsOf: index) == before)
}

@Test func repositorySupportsUnbornBranchesAndCleanTrees() throws {
    let fixture = try RepositoryFixture()
    let empty = try GitRepository.scan(fixture.root)
    #expect(empty.head == nil && empty.changes.isEmpty)
    try fixture.write("first.txt", "first")
    try fixture.git("add", "first.txt")
    let unborn = try GitRepository.scan(fixture.root)
    let pair = try GitRepository.comparison(for: #require(unborn.changes.first), in: unborn)
    #expect(pair.original == "" && pair.changed == "first")
    try fixture.commit()
    #expect(try GitRepository.scan(fixture.root).changes.isEmpty)
}

@Test func repositoryRenamesAndLiteralFilenames() throws {
    let fixture = try RepositoryFixture()
    let original = "folder/old\t日本語\n.txt"
    let renamed = "folder/new\t日本語\n.txt"
    let literal = ":(glob)*[x]?.txt"
    let combining = "\u{0301}name.txt"
    try fixture.write(original, "rename me")
    try fixture.write(literal, "literal old")
    try fixture.write(combining, "combining old")
    try fixture.commit()
    try fixture.git("mv", "--", original, renamed)
    try fixture.write(renamed, "rename me with edits")
    try fixture.write(literal, "literal new")
    try fixture.write(combining, "combining new")
    let snapshot = try GitRepository.scan(fixture.root)
    let rename = try #require(snapshot.changes.first { $0.path == renamed })
    #expect(rename.originalPath == original)
    #expect(rename.status == "Renamed")
    let pair = try GitRepository.comparison(for: rename, in: snapshot)
    #expect(pair.original == "rename me" && pair.changed == "rename me with edits")
    let literalPair = try GitRepository.comparison(for: #require(snapshot.changes.first { $0.path == literal }), in: snapshot)
    #expect(literalPair.original == "literal old" && literalPair.changed == "literal new")
    let combiningPair = try GitRepository.comparison(for: #require(snapshot.changes.first { $0.path == combining }), in: snapshot)
    #expect(combiningPair.original == "combining old" && combiningPair.changed == "combining new")
}

@Test func repositoryRejectsBinaryOversizedAndSymbolicLinkInputs() throws {
    let fixture = try RepositoryFixture()
    try fixture.write("binary", "old")
    try fixture.write("large", String(repeating: "x", count: TextFileReader.maximumByteCount + 1))
    try fixture.commit()
    try Data([0, 1, 2]).write(to: fixture.root.appendingPathComponent("binary"))
    try fixture.write("large", "small now")
    try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("link").path, withDestinationPath: "binary")
    let snapshot = try GitRepository.scan(fixture.root)
    #expect(snapshot.changes.count == 3)
    for change in snapshot.changes {
        #expect(throws: (any Error).self) { try GitRepository.comparison(for: change, in: snapshot) }
    }
}

@Test func repositoryReadsSnapshotsByCommitAndSupportsDetachedHeadAndWorktrees() throws {
    let fixture = try RepositoryFixture()
    try fixture.write("file", "first")
    try fixture.commit()
    try fixture.write("file", "second")
    let old = try GitRepository.scan(fixture.root)
    try fixture.commit()
    let pair = try GitRepository.comparison(for: #require(old.changes.first), in: old)
    #expect(pair.original == "first" && pair.changed == "second")
    try fixture.git("checkout", "--detach")
    #expect(try GitRepository.scan(fixture.root).branch == "Detached HEAD")
    let worktree = fixture.root.appendingPathComponent("linked")
    try fixture.git("worktree", "add", "--detach", worktree.path)
    try Data("linked change".utf8).write(to: worktree.appendingPathComponent("file"))
    let linked = try GitRepository.scan(worktree)
    let linkedPair = try GitRepository.comparison(for: #require(linked.changes.first), in: linked)
    #expect(linkedPair.original == "second" && linkedPair.changed == "linked change")
}

@Test func repositoryConflictsAndInvalidFoldersGiveErrors() throws {
    let changes = try GitRepository.parseStatus(Data("UU conflict.txt\0AA both.txt\0DD deleted.txt\0".utf8))
    #expect(changes.allSatisfy { $0.isConflicted })
    let fixture = try RepositoryFixture()
    let snapshot = try GitRepository.scan(fixture.root)
    #expect(throws: (any Error).self) { try GitRepository.comparison(for: changes[0], in: snapshot) }
    #expect(throws: (any Error).self) { try GitRepository.scan(fixture.root.deletingLastPathComponent()) }
}

@Test func stagedDeletionWithRecreatedFileAppearsOnceWithCommittedBase() throws {
    let fixture = try RepositoryFixture()
    try fixture.write("recreated", "committed")
    try fixture.commit()
    try fixture.git("rm", "recreated")
    try fixture.write("recreated", "back again")
    let snapshot = try GitRepository.scan(fixture.root)
    #expect(snapshot.changes.count == 1)
    let change = try #require(snapshot.changes.first)
    #expect(change.status == "Recreated")
    let pair = try GitRepository.comparison(for: change, in: snapshot)
    #expect(pair.original == "committed" && pair.changed == "back again")
}

@Test func untrackedEmbeddedRepositoryIsAPathNotAnEmptyTreeComponent() throws {
    let fixture = try RepositoryFixture()
    try fixture.git("init", "nested")
    let snapshot = try GitRepository.scan(fixture.root)
    let directory = try #require(snapshot.changes.first)
    #expect(directory.path == "nested")
    #expect(directory.isUntracked)
    #expect(throws: (any Error).self) { try GitRepository.comparison(for: directory, in: snapshot) }
}

@Test func branchBaselineKeepsWorkingScopeAndReadsUntrackedPathsFromBranch() throws {
    let fixture = try RepositoryFixture()
    try fixture.write("edited", "base")
    try fixture.write("unrelated", "base")
    try fixture.commit()
    try fixture.git("checkout", "-b", "feature-b")
    try fixture.git("checkout", "main")
    try fixture.write("edited", "matches main")
    try fixture.write("unrelated", "main only change")
    try fixture.write("new", "also on main")
    try fixture.commit()
    try fixture.git("checkout", "feature-b")
    try fixture.write("edited", "matches main")
    try fixture.write("new", "also on main")
    let index = fixture.root.appendingPathComponent(".git/index")
    let before = try Data(contentsOf: index)
    let snapshot = try GitRepository.scan(fixture.root)
    #expect(snapshot.branches.map(\.name) == ["feature-b", "main"])
    #expect(snapshot.changes.map(\.path) == ["edited", "new"])
    let baseline = try #require(snapshot.branches.first { $0.name == "main" })
    for change in snapshot.changes {
        let pair = try GitRepository.comparison(for: change, in: snapshot, baseline: baseline)
        #expect(pair.original == pair.changed)
        #expect(pair.isIdentical)
        let defaultPair = try GitRepository.comparison(for: change, in: snapshot)
        #expect(!defaultPair.isIdentical)
    }
    // A moving branch cannot change the meaning of an already loaded snapshot.
    try fixture.git("branch", "-f", "main", "feature-b")
    let pinned = try GitRepository.comparison(for: #require(snapshot.changes.first), in: snapshot, baseline: baseline)
    #expect(pinned.isIdentical)
    #expect(try Data(contentsOf: index) == before)
    #expect(try fixture.git("branch", "--show-current") == Data("feature-b\n".utf8))
}

@Test func branchBaselineUsesCurrentRenamePathAndHandlesMissingFiles() throws {
    let fixture = try RepositoryFixture()
    try fixture.write("old", "rename me")
    try fixture.write("deleted", "delete me")
    try fixture.commit()
    try fixture.git("branch", "feature-b")
    try fixture.git("mv", "old", "new")
    try fixture.git("rm", "deleted")
    try fixture.commit()
    try fixture.git("checkout", "feature-b")
    try fixture.git("mv", "old", "new")
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("deleted"))
    try fixture.write("empty-added", "")
    let snapshot = try GitRepository.scan(fixture.root)
    let baseline = try #require(snapshot.branches.first { $0.name == "main" })
    let renamed = try #require(snapshot.changes.first { $0.path == "new" })
    #expect(renamed.originalPath == "old")
    #expect(try GitRepository.comparison(for: renamed, in: snapshot, baseline: baseline).isIdentical)
    #expect(try GitRepository.comparison(for: renamed, in: snapshot).original == "rename me")
    let absent = try GitRepository.comparison(for: #require(snapshot.changes.first { $0.path == "deleted" }), in: snapshot, baseline: baseline)
    #expect(absent.isIdentical && absent.original.isEmpty && absent.changed.isEmpty)
    let emptyAdded = try GitRepository.comparison(for: #require(snapshot.changes.first { $0.path == "empty-added" }), in: snapshot, baseline: baseline)
    #expect(!emptyAdded.isIdentical)
}

@Test func identicalBaselineRequiresMatchingBytesAndMode() throws {
    let fixture = try RepositoryFixture()
    try fixture.write("mode", "same")
    try fixture.write("encoding", "same")
    try fixture.write("deleted-empty", "")
    try fixture.commit()
    try fixture.git("branch", "other")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.appendingPathComponent("mode").path)
    try Data([0xEF, 0xBB, 0xBF] + Array("same".utf8)).write(to: fixture.root.appendingPathComponent("encoding"))
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("deleted-empty"))
    let snapshot = try GitRepository.scan(fixture.root)
    let baseline = try #require(snapshot.branches.first { $0.name == "other" })
    #expect(snapshot.changes.count == 3)
    for change in snapshot.changes {
        let pair = try GitRepository.comparison(for: change, in: snapshot, baseline: baseline)
        #expect(pair.original == pair.changed)
        #expect(!pair.isIdentical)
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
    let snapshot = try GitRepository.scan(fixture.root, mode: .lastCommit)
    #expect(snapshot.reviewMode == .lastCommit)
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
    let unborn = try GitRepository.scan(fixture.root, mode: .lastCommit)
    #expect(unborn.commit == nil && unborn.changes.isEmpty)
    try fixture.commit()
    let initial = try GitRepository.scan(fixture.root, mode: .lastCommit)
    #expect(initial.commit?.parents.isEmpty == true)
    let pair = try GitRepository.comparison(for: #require(initial.changes.first), in: initial)
    #expect(pair.original.isEmpty && pair.changed == "first contents")
    try fixture.git("commit", "--allow-empty", "-m", "Empty commit")
    try fixture.git("checkout", "--detach")
    let empty = try GitRepository.scan(fixture.root, mode: .lastCommit)
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
    let snapshot = try GitRepository.scan(fixture.root, mode: .lastCommit)
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
    let snapshot = try GitRepository.scan(fixture.root, mode: .lastCommit)
    #expect(snapshot.changes.count == 3)
    for change in snapshot.changes {
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(change.path))
        try fixture.write(change.path, "readable working copy")
        #expect(throws: (any Error).self) { try GitRepository.comparison(for: change, in: snapshot) }
    }
}
