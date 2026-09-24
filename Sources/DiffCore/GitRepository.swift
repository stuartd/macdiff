import Foundation

public struct GitChange: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let originalPath: String?
    public let indexStatus: Character
    public let worktreeStatus: Character

    public var isUntracked: Bool { indexStatus == "?" }
    public var isConflicted: Bool {
        indexStatus == "U" || worktreeStatus == "U" ||
        (indexStatus == "A" && worktreeStatus == "A") ||
        (indexStatus == "D" && worktreeStatus == "D")
    }
    public var status: String {
        if isConflicted { return "Conflict" }
        if isUntracked { return "Untracked" }
        if indexStatus == "R" { return "Renamed" }
        if indexStatus == "D" && worktreeStatus == "A" { return "Recreated" }
        if indexStatus == "D" || worktreeStatus == "D" { return "Deleted" }
        if indexStatus == "A" { return "Added" }
        if indexStatus == "T" || worktreeStatus == "T" { return "Type changed" }
        return "Modified"
    }
    public var stagingDescription: String {
        if isUntracked { return "Not tracked by Git" }
        if isConflicted { return "Resolve this conflict in your editor" }
        if indexStatus != " " && worktreeStatus != " " { return "Staged and unstaged changes" }
        return indexStatus != " " ? "Staged changes" : "Unstaged changes"
    }
}

public struct GitSnapshot: Sendable {
    public let root: URL
    public let branch: String
    public let head: String?
    public let changes: [GitChange]
}

public struct GitComparison: Sendable {
    public let original: String
    public let changed: String
}

public enum GitRepository {
    private struct GitError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    public static func scan(_ directory: URL) throws -> GitSnapshot {
        let rootData = try run(["rev-parse", "--show-toplevel"], at: directory)
        // Git appends exactly one newline; spaces and newlines can be part of a path.
        guard var rootPath = String(data: rootData, encoding: .utf8), rootPath.hasSuffix("\n") else {
            throw GitError("The repository path is not valid UTF-8.")
        }
        rootPath.removeLast()
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let headResult = try command(["rev-parse", "--verify", "--quiet", "HEAD"], at: root)
        guard headResult.status == 0 || headResult.status == 1 else { throw GitError(headResult.error) }
        let head = headResult.status == 0 ? String(decoding: headResult.data, as: UTF8.self).trimmingCharacters(in: .newlines) : nil
        let branchResult = try command(["symbolic-ref", "--quiet", "--short", "HEAD"], at: root)
        let branch = branchResult.status == 0 ? String(decoding: branchResult.data, as: UTF8.self).trimmingCharacters(in: .newlines) : "Detached HEAD"
        let status = try run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none", "--renames"], at: root)
        return GitSnapshot(root: root, branch: branch, head: head, changes: try parseStatus(status))
    }

    static func parseStatus(_ data: Data) throws -> [GitChange] {
        let records = data.split(separator: 0)
        var result: [GitChange] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 4, let rawPath = String(data: record.dropFirst(3), encoding: .utf8) else {
                throw GitError("Git returned a filename that cannot be displayed as UTF-8.")
            }
            // Status has a fixed byte prefix, independent of filename graphemes.
            let flags = Array(String(decoding: record.prefix(2), as: UTF8.self))
            // Untracked embedded repositories are reported as directory/ even
            // with --untracked-files=all. Keep tree node IDs free of trailing /.
            let path = rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
            var original: String?
            if flags[0] == "R" || flags[0] == "C" || flags[1] == "R" || flags[1] == "C" {
                index += 1
                guard index < records.count, let name = String(data: records[index], encoding: .utf8) else {
                    throw GitError("Git returned an invalid rename record.")
                }
                original = name
            }
            result.append(GitChange(path: path, originalPath: original, indexStatus: flags[0], worktreeStatus: flags[1]))
            index += 1
        }
        // A staged deletion followed by recreating the file produces both D and ??
        // records. Present one working-tree comparison against its committed base.
        let grouped = Dictionary(grouping: result, by: \.path)
        return grouped.values.map { entries in
            if entries.count > 1, entries.contains(where: { $0.isUntracked }),
               let tracked = entries.first(where: { !$0.isUntracked }) {
                return GitChange(path: tracked.path, originalPath: tracked.originalPath,
                                 indexStatus: tracked.indexStatus, worktreeStatus: "A")
            }
            return entries[0]
        }.sorted { $0.path < $1.path }
    }

    public static func comparison(for change: GitChange, in snapshot: GitSnapshot) throws -> GitComparison {
        if change.isConflicted {
            throw GitError("This file has an unresolved merge conflict. Resolve it in your editor, then refresh.")
        }
        var original = ""
        if let head = snapshot.head, !change.isUntracked {
            let path = change.originalPath ?? change.path
            let entry = try run(["ls-tree", "-z", head, "--", path], at: snapshot.root)
            if !entry.isEmpty {
                // Read by object ID so filenames are never interpreted as revision syntax.
                let metadata = String(decoding: entry.prefix { $0 != 9 }, as: UTF8.self).split(separator: " ")
                guard metadata.count == 3, metadata[0] == "100644" || metadata[0] == "100755", metadata[1] == "blob" else {
                    throw GitError("Symbolic links and submodules cannot be shown as text diffs.")
                }
                original = try TextFileReader.decode(run(["cat-file", "blob", String(metadata[2])], at: snapshot.root, limit: TextFileReader.maximumByteCount))
            }
        }
        try Task.checkCancellation()
        let url = snapshot.root.appendingPathComponent(change.path)
        var changed = ""
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let rootPath = snapshot.root.resolvingSymlinksInPath().path + "/"
            guard url.resolvingSymlinksInPath().path.utf8.starts(with: rootPath.utf8) else {
                throw GitError("This path points outside the repository and cannot be shown.")
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw GitError("Symbolic links, directories, and submodules cannot be shown as text diffs.")
            }
            changed = try TextFileReader.read(url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // A deleted file has an explicitly empty working-tree side.
        }
        return GitComparison(original: original, changed: changed)
    }

    private static func run(_ arguments: [String], at directory: URL, limit: Int = 16 * 1_024 * 1_024) throws -> Data {
        let result = try command(arguments, at: directory, limit: limit)
        guard result.status == 0 else { throw GitError(result.error.isEmpty ? "Git could not read this repository." : result.error) }
        return result.data
    }

    private static func command(_ arguments: [String], at directory: URL, limit: Int = 16 * 1_024 * 1_024) throws -> (data: Data, status: Int32, error: String) {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        process.arguments = ["--no-optional-locks", "--no-pager", "--literal-pathspecs", "-c", "core.fsmonitor=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        // An inherited Git context must not redirect reads to another repository.
        for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("macdiff-git-\(UUID())")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorURL) }
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }
        process.standardError = errorHandle
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            guard data.count + chunk.count <= limit else {
                throw GitError(limit == TextFileReader.maximumByteCount ? "Text must be 5 MiB or smaller." : "This repository has too many changed paths to display.")
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        let errors = try FileHandle(forReadingFrom: errorURL)
        defer { try? errors.close() }
        let errorData = try errors.read(upToCount: 16_384) ?? Data()
        return (data, process.terminationStatus, String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
