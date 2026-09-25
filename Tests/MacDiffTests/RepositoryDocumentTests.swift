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
    while document.isScanningRepository || document.isLoadingRepositoryFile || document.isComparing || document.isCheckingRepositoryBaseline {
        guard ContinuousClock.now < deadline else { throw NSError(domain: "RepositoryTimeout", code: 1) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test @MainActor func repositorySelectionRefreshAndUnreadableFiles() async throws {
    let root = try makeDocumentRepository()
    defer { try? FileManager.default.removeItem(at: root) }
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
    #expect(document.rightText == "updated")
    document.selectRepositoryPath("binary")
    try await waitForRepository(document)
    #expect(!document.hasBothInputs && document.rows.isEmpty)
    #expect(document.repositoryMessage?.contains("binary") == true)
    document.selectRepositoryPath("a.txt")
    document.selectRepositoryPath("b.txt")
    try await waitForRepository(document)
    #expect(document.rightText == "updated" && document.repositoryMessage == nil)
    try FileManager.default.removeItem(at: root.appendingPathComponent("b.txt"))
    document.refreshRepository()
    try await waitForRepository(document)
    #expect(document.selectedRepositoryPath == "a.txt")
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

private func makeBaselineRepository() throws -> URL {
    let root = try makeDocumentRepository()
    try documentGit(root, "add", "--all")
    try documentGit(root, "commit", "-m", "Base")
    try documentGit(root, "branch", "feature-b")
    try Data("target a".utf8).write(to: root.appendingPathComponent("a.txt"))
    try Data("target b".utf8).write(to: root.appendingPathComponent("b.txt"))
    try documentGit(root, "commit", "-am", "Main changes")
    try documentGit(root, "checkout", "feature-b")
    try Data("target a".utf8).write(to: root.appendingPathComponent("a.txt"))
    try Data("target b".utf8).write(to: root.appendingPathComponent("b.txt"))
    return root
}

@Test @MainActor func baselineCanChangeWithoutSelectionAndKeepsWorkingFiles() async throws {
    let root = try makeBaselineRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let document = DiffDocument()
    document.openRepository(root)
    try await waitForRepository(document)
    let paths = document.repository?.changes.map(\.path)
    #expect(document.leftText == "one")
    document.selectRepositoryPath(nil)
    document.selectRepositoryBaseline("refs/heads/main")
    try await waitForRepository(document)
    #expect(document.selectedRepositoryPath == nil && !document.hasBothInputs)
    #expect(document.identicalRepositoryPaths == ["a.txt", "b.txt"])
    #expect(document.repository?.changes.map(\.path) == paths)
    document.selectRepositoryPath("b.txt")
    try await waitForRepository(document)
    #expect(document.leftText == "target b" && document.rightText == "target b")
    #expect(document.selectedRepositoryFileIsIdentical && document.changeStarts.isEmpty)
    #expect(!document.rows.isEmpty) // Matching contents remain available to inspect.
    document.selectRepositoryBaseline(nil)
    try await waitForRepository(document)
    #expect(document.selectedRepositoryPath == "b.txt")
    #expect(document.leftText == "two" && document.rightText == "target b")
    #expect(document.identicalRepositoryPaths.isEmpty)
    #expect(document.repository?.changes.map(\.path) == paths)
}

@Test @MainActor func baselineRefreshTracksBranchMovesAndRecoversFromDeletion() async throws {
    let root = try makeBaselineRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let document = DiffDocument()
    document.openRepository(root)
    try await waitForRepository(document)
    document.selectRepositoryBaseline("refs/heads/main")
    document.selectRepositoryPath("b.txt")
    try await waitForRepository(document)
    document.refreshRepository()
    try await waitForRepository(document)
    #expect(document.repositoryBaselineRef == "refs/heads/main")
    #expect(document.selectedRepositoryPath == "b.txt")
    #expect(document.selectedRepositoryFileIsIdentical)
    try documentGit(root, "branch", "-f", "main", "feature-b")
    document.refreshRepository()
    try await waitForRepository(document)
    #expect(document.repositoryBaselineRef == "refs/heads/main")
    #expect(document.leftText == "two")
    #expect(document.identicalRepositoryPaths.isEmpty)
    try documentGit(root, "branch", "-D", "main")
    document.refreshRepository()
    try await waitForRepository(document)
    #expect(document.repositoryBaselineRef == nil)
    #expect(document.repositoryBaselineNotice?.contains("no longer available") == true)
    #expect(document.selectedRepositoryPath == "b.txt" && document.leftText == "two")
}

@Test @MainActor func obsoleteBaselineWorkCannotReplaceNewSelectionOrManualInputs() async throws {
    let root = try makeBaselineRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let document = DiffDocument()
    document.openRepository(root)
    try await waitForRepository(document)
    document.selectRepositoryBaseline("refs/heads/main")
    document.selectRepositoryBaseline(nil)
    document.selectRepositoryPath("b.txt")
    try await waitForRepository(document)
    #expect(document.repositoryBaselineRef == nil)
    #expect(document.leftText == "two" && document.identicalRepositoryPaths.isEmpty)
    document.selectRepositoryBaseline("refs/heads/main")
    document.setText("manual", onLeft: true)
    try await Task.sleep(for: .milliseconds(300))
    #expect(!document.isRepositoryMode && document.repositoryBaselineRef == nil)
    #expect(document.identicalRepositoryPaths.isEmpty && !document.isCheckingRepositoryBaseline)
    #expect(document.leftText == "manual")
}
#endif
