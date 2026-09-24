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
#endif
