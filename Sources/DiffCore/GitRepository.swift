import Foundation

public struct GitChange: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let originalPath: String?
    public let changeStatus: Character

    public var status: String {
        switch changeStatus {
        case "R": "Renamed"
        case "C": "Copied"
        case "D": "Deleted"
        case "A": "Added"
        case "T": "Type changed"
        default: "Modified"
        }
    }
}

public struct GitCommit: Identifiable, Equatable, Sendable {
    public let id: String
    public let subject: String
    public let parents: [String]
    public var shortID: String { String(id.prefix(7)) }
    public var baselineLabel: String {
        guard let parent = parents.first else { return "Before · Empty tree" }
        let role = parents.count > 1 ? " (first parent)" : ""
        return "Before · \(parent.prefix(7))\(role)"
    }
    public var targetLabel: String { "After · \(shortID)" }
}

public struct GitSnapshot: Sendable {
    public let root: URL
    public let branch: String
    public let head: String?
    public let changes: [GitChange]
    public let commit: GitCommit?
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

    public static func scan(_ directory: URL, commitID: String? = nil) async throws -> GitSnapshot {
        let rootData = try await run(["rev-parse", "--show-toplevel"], at: directory)
        // Git appends exactly one newline; spaces and newlines can be part of a path.
        guard var rootPath = String(data: rootData, encoding: .utf8), rootPath.hasSuffix("\n") else {
            throw GitError("The repository path is not valid UTF-8.")
        }
        rootPath.removeLast()
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let headResult = try await command(["rev-parse", "--verify", "--quiet", "HEAD"], at: root)
        guard headResult.status == 0 || headResult.status == 1 else { throw GitError(headResult.error) }
        let head = headResult.status == 0 ? String(decoding: headResult.data, as: UTF8.self).trimmingCharacters(in: .newlines) : nil
        let branchResult = try await command(["symbolic-ref", "--quiet", "--short", "HEAD"], at: root)
        let branch = branchResult.status == 0 ? String(decoding: branchResult.data, as: UTF8.self).trimmingCharacters(in: .newlines) : "Detached HEAD"
        let commit: GitCommit?
        if let id = commitID ?? head { commit = try await readCommit(id, at: root) }
        else { commit = nil }
        var changes: [GitChange] = []
        if let commit {
            var arguments = ["diff-tree", "--no-commit-id", "--name-status", "-r", "-z", "--find-renames", "--no-ext-diff", "--no-textconv"]
            if let parent = commit.parents.first {
                arguments += [parent, commit.id, "--"]
            } else {
                arguments += ["--root", commit.id, "--"]
            }
            let data = try await run(arguments, at: root)
            changes = try parseCommitChanges(data)
        }
        return GitSnapshot(root: root, branch: branch, head: head, changes: changes, commit: commit)
    }

    private static func readCommit(_ id: String, at root: URL) async throws -> GitCommit {
        guard (7...64).contains(id.count), id.allSatisfy({ $0.isHexDigit }) else {
            throw GitError("Choose a valid commit hash.")
        }
        let resolved = String(decoding: try await run(["rev-parse", "--verify", "\(id)^{commit}"], at: root), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        // Read actual parents, including parents unavailable in a shallow clone.
        let raw = String(decoding: try await run(["cat-file", "commit", resolved], at: root), as: UTF8.self)
        let parts = raw.components(separatedBy: "\n\n")
        let parents = parts[0].split(separator: "\n").filter { $0.hasPrefix("parent ") }.map { String($0.dropFirst(7)) }
        let subject = parts.dropFirst().joined(separator: "\n\n").split(separator: "\n").first.map(String.init) ?? "(No commit message)"
        return GitCommit(id: resolved, subject: subject, parents: parents)
    }

    /// Search the captured HEAD's history by message, or look up a commit by hash.
    public static func history(in snapshot: GitSnapshot, query: String = "", limit: Int = 101) async throws -> [GitCommit] {
        guard let head = snapshot.head else { return [] }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = ["log", "--no-show-signature", "--no-notes", "--encoding=UTF-8", "--color=never", "--topo-order", "--format=%H%x00%P%x00%s", "--max-count=\(max(1, limit))"]
        if !query.isEmpty { arguments += ["--fixed-strings", "--regexp-ignore-case", "--grep=\(query)"] }
        arguments += [head, "--"]
        let data = try await run(arguments, at: snapshot.root)
        var commits = try data.split(separator: 10).map { record -> GitCommit in
            let fields = record.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count == 3 else { throw GitError("Git returned an invalid commit record.") }
            return GitCommit(id: String(decoding: fields[0], as: UTF8.self),
                             subject: fields[2].isEmpty ? "(No commit message)" : String(decoding: fields[2], as: UTF8.self),
                             parents: String(decoding: fields[1], as: UTF8.self).split(separator: " ").map(String.init))
        }
        if (7...64).contains(query.count), query.allSatisfy({ $0.isHexDigit }),
           let match = try? await readCommit(query, at: snapshot.root), !commits.contains(where: { $0.id == match.id }) {
            commits.insert(match, at: 0)
        }
        try Task.checkCancellation()
        return commits
    }

    static func parseCommitChanges(_ data: Data) throws -> [GitChange] {
        let records = data.split(separator: 0)
        var changes: [GitChange] = []
        var index = 0
        func path(at index: Int) throws -> String {
            guard records.indices.contains(index), let path = String(data: records[index], encoding: .utf8) else {
                throw GitError("Git returned a filename that cannot be displayed as UTF-8.")
            }
            return path
        }
        while index < records.count {
            guard let status = String(decoding: records[index], as: UTF8.self).first,
                  "AMDRCT".contains(status) else { throw GitError("Git returned an invalid commit change record.") }
            index += 1
            let firstPath = try path(at: index)
            index += 1
            let isRename = status == "R" || status == "C"
            let currentPath = try isRename ? path(at: index) : firstPath
            if isRename { index += 1 }
            changes.append(GitChange(path: currentPath, originalPath: isRename ? firstPath : nil,
                                     changeStatus: status))
        }
        return changes.sorted { $0.path < $1.path }
    }

    public static func comparison(for change: GitChange, in snapshot: GitSnapshot) async throws -> GitComparison {
        guard let commit = snapshot.commit else { throw GitError("This repository has no commits yet.") }
        let original = try await committedFile(
            at: change.originalPath ?? change.path,
            revision: change.changeStatus == "A" ? nil : commit.parents.first, root: snapshot.root)
        let changed = try await committedFile(
            at: change.path, revision: change.changeStatus == "D" ? nil : commit.id, root: snapshot.root)
        return GitComparison(original: original, changed: changed)
    }

    private static func committedFile(at path: String, revision: String?, root: URL) async throws -> String {
        guard let revision else { return "" }
        let entry = try await run(["ls-tree", "-z", revision, "--", path], at: root)
        guard !entry.isEmpty else { return "" }
        // Read by object ID so filenames are never interpreted as revision syntax.
        let metadata = String(decoding: entry.prefix { $0 != 9 }, as: UTF8.self).split(separator: " ")
        guard metadata.count == 3, metadata[0] == "100644" || metadata[0] == "100755", metadata[1] == "blob" else {
            throw GitError("Symbolic links and submodules cannot be shown as text diffs.")
        }
        let data = try await run(["cat-file", "blob", String(metadata[2])], at: root, limit: TextFileReader.maximumByteCount)
        return try TextFileReader.decode(data)
    }

    private static func run(_ arguments: [String], at directory: URL, limit: Int = 16 * 1_024 * 1_024) async throws -> Data {
        let result = try await command(arguments, at: directory, limit: limit)
        guard result.status == 0 else { throw GitError(result.error.isEmpty ? "Git could not read this repository." : result.error) }
        return result.data
    }

    private static func command(_ arguments: [String], at directory: URL, limit: Int = 16 * 1_024 * 1_024) async throws -> ProcessRunner.Result {
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
        return try await ProcessRunner.run(process, outputLimit: limit,
            limitMessage: limit == TextFileReader.maximumByteCount
                ? "Text must be 5 MiB or smaller."
                : "This repository has too many changed paths to display.")
    }
}
