#if os(macOS)
import Foundation
import Testing
@testable import MacDiff

private func makeDocumentRepository() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("macdiff-document-repo-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["init", "-b", "main", root.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    try Data("one".utf8).write(to: root.appendingPathComponent("a.txt"))
    try Data("two".utf8).write(to: root.appendingPathComponent("b.txt"))
    try Data([0, 1]).write(to: root.appendingPathComponent("binary"))
    return root
}

@MainActor private func waitForRepository(_ document: DiffDocument) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while document.isScanningRepository || document.isLoadingRepositoryFile || document.isComparing {
        guard ContinuousClock.now < deadline else { throw NSError(domain: "RepositoryTimeout", code: 1) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test @MainActor func repositorySelectionRefreshAndUnreadableFiles() async throws {
    let root = try makeDocumentRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    try documentGit(root, "add", "--all")
    try documentGit(root, "commit", "-m", "First")
    let document = DiffDocument()
    document.openRepository(root)
    try await waitForRepository(document)
    #expect(document.isRepositoryMode)
    #expect(document.repository?.changes.count == 3)
    #expect(document.selectedRepositoryPath == "a.txt")
    #expect(document.leftText == "" && document.rightText == "one")
    document.selectRepositoryPath("b.txt")
    try await waitForRepository(document)
    #expect(document.rightText == "two")
    try Data("updated".utf8).write(to: root.appendingPathComponent("b.txt"))
    document.refreshRepository()
    try await waitForRepository(document)
    #expect(document.selectedRepositoryPath == "b.txt")
    #expect(document.rightText == "two")
    document.selectRepositoryPath("binary")
    try await waitForRepository(document)
    #expect(!document.hasBothInputs && document.rows.isEmpty)
    #expect(document.repositoryMessage?.contains("binary") == true)
    document.selectRepositoryPath("a.txt")
    document.selectRepositoryPath("b.txt")
    try await waitForRepository(document)
    #expect(document.rightText == "two" && document.repositoryMessage == nil)
    try FileManager.default.removeItem(at: root.appendingPathComponent("b.txt"))
    try documentGit(root, "add", "--all")
    try documentGit(root, "commit", "-m", "Delete b")
    document.refreshRepository()
    try await waitForRepository(document)
    #expect(document.selectedRepositoryPath == "b.txt")
    #expect(document.leftText == "two" && document.rightText.isEmpty)
}

@Test @MainActor func leavingRepositoryCancelsPendingScansAndSelections() async throws {
    let root = try makeDocumentRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let document = DiffDocument()
    document.openRepository(root)
    document.clear()
    try await Task.sleep(for: .milliseconds(300))
    #expect(!document.isRepositoryMode && !document.hasBothInputs)
    #expect(document.repository == nil && document.repositoryMessage == nil)
    document.openRepository(root)
    try await waitForRepository(document)
    document.selectRepositoryPath("b.txt")
    document.setText("manual original", onLeft: true)
    document.setText("manual changed", onLeft: false)
    try await Task.sleep(for: .milliseconds(300))
    #expect(!document.isRepositoryMode)
    #expect(document.leftText == "manual original" && document.rightText == "manual changed")
}

@discardableResult private func documentGit(_ root: URL, _ arguments: String...) throws -> Data {
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
    guard process.terminationStatus == 0 else { throw NSError(domain: "DocumentGit", code: Int(process.terminationStatus)) }
    return data
}

@Test @MainActor func selectingOlderCommitsStaysPinnedAndLatestFollowsHead() async throws {
    let root = try makeDocumentRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    try documentGit(root, "add", "--all")
    try documentGit(root, "commit", "-m", "First")
    let document = DiffDocument()
    document.openRepository(root)
    try await waitForRepository(document)
    let first = try #require(document.repository?.commit?.id)
    try Data("second".utf8).write(to: root.appendingPathComponent("a.txt"))
    try documentGit(root, "commit", "-am", "Second")
    document.refreshRepository()
    try await waitForRepository(document)
    #expect(document.leftText == "one" && document.rightText == "second")
    #expect(document.repository?.commit?.subject == "Second")
    document.selectRepositoryCommit(first)
    try await waitForRepository(document)
    #expect(document.leftText.isEmpty && document.rightText == "one")
    try Data("third".utf8).write(to: root.appendingPathComponent("a.txt"))
    try documentGit(root, "commit", "-am", "Third")
    document.refreshRepository()
    try await waitForRepository(document)
    #expect(document.repository?.commit?.id == first && document.rightText == "one")
    document.selectRepositoryCommit(nil)
    try await waitForRepository(document)
    #expect(document.leftText == "second" && document.rightText == "third")
    document.selectRepositoryCommit(first)
    document.selectRepositoryCommit(nil)
    try await waitForRepository(document)
    #expect(document.repository?.commit?.subject == "Third")
    document.selectRepositoryCommit(first)
    document.clear()
    try await Task.sleep(for: .milliseconds(300))
    #expect(document.repository == nil && !document.hasBothInputs)
    #expect(document.selectedRepositoryCommitID == nil)
}

@Test @MainActor func commitReviewHasDistinctUnbornAndEmptyStates() async throws {
    let root = try makeDocumentRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let document = DiffDocument()
    document.openRepository(root)
    try await waitForRepository(document)
    #expect(document.repositoryEmptyTitle == "No commits yet")
    #expect(!document.hasBothInputs && document.repositoryMessage == nil)
    try documentGit(root, "add", "a.txt")
    try documentGit(root, "commit", "-m", "First")
    document.refreshRepository()
    try await waitForRepository(document)
    #expect(document.repositoryBaselineLabel == "Before")
    #expect(document.leftText.isEmpty && document.rightText == "one")
    try documentGit(root, "commit", "--allow-empty", "-m", "Empty")
    document.refreshRepository()
    try await waitForRepository(document)
    #expect(document.repositoryEmptyTitle == "This commit has no file changes")
    #expect(!document.hasBothInputs && document.selectedRepositoryPath == nil)
}
#endif
