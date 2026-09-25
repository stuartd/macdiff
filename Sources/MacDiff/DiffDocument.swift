#if os(macOS)
import Combine
import Foundation
import DiffCore

@MainActor
final class DiffDocument: ObservableObject {
    @Published private(set) var leftText = ""
    @Published private(set) var rightText = ""
    @Published private(set) var leftURL: URL?
    @Published private(set) var rightURL: URL?
    @Published private(set) var hasLeft = false
    @Published private(set) var hasRight = false
    @Published private(set) var rows: [DiffRow] = []
    @Published private(set) var changeStarts: [Int] = []
    @Published private(set) var selectedChange: Int?
    @Published private(set) var isComparing = false
    @Published private(set) var isLoadingLeft = false
    @Published private(set) var isLoadingRight = false
    @Published private(set) var addedCount = 0
    @Published private(set) var removedCount = 0
    @Published private(set) var modifiedCount = 0
    @Published private(set) var longestLineCharacterCount = 0
    @Published var errorMessage: String?
    @Published var ignoreWhitespace = false {
        didSet {
            if oldValue != ignoreWhitespace { scheduleComparison() }
        }
    }

    @Published private(set) var repository: GitSnapshot?
    @Published private(set) var repositoryReviewMode: GitReviewMode = .workingChanges
    @Published private(set) var repositoryURL: URL?
    @Published private(set) var selectedRepositoryPath: String?
    @Published private(set) var isScanningRepository = false
    @Published private(set) var isLoadingRepositoryFile = false
    @Published private(set) var repositoryMessage: String?
    @Published private(set) var repositoryBaselineRef: String?
    @Published private(set) var repositoryBaselineNotice: String?
    @Published private(set) var identicalRepositoryPaths: Set<String> = []
    @Published private(set) var selectedRepositoryFileIsIdentical = false
    @Published private(set) var isCheckingRepositoryBaseline = false
    var isChoosingRepository = false
    private var repositoryTask: Task<Void, Never>?
    private var repositoryFileTask: Task<Void, Never>?
    private var repositoryBaselineTask: Task<Void, Never>?
    private var repositoryBaselineGeneration = UUID()
    private var repositoryGeneration = UUID()
    private var repositoryFileGeneration = UUID()

    var isRepositoryMode: Bool { repositoryURL != nil }
    var selectedRepositoryChange: GitChange? {
        repository?.changes.first { $0.path == selectedRepositoryPath }
    }
    var repositoryBaseline: GitBranch? {
        guard repositoryReviewMode == .workingChanges else { return nil }
        return repository?.branches.first { $0.id == repositoryBaselineRef }
    }
    var repositoryBaselineLabel: String {
        if repositoryReviewMode == .lastCommit {
            guard let parent = repository?.commit?.parents.first else { return "Empty base" }
            let title = (repository?.commit?.parents.count ?? 0) > 1 ? "First parent" : "Parent"
            return "\(title) · \(parent.prefix(7))"
        }
        return repositoryBaseline?.name ?? (repository?.head == nil ? "Empty base" : "Last commit on \(repository?.branch ?? "HEAD")")
    }
    var repositoryTargetLabel: String {
        if repositoryReviewMode == .lastCommit {
            return repository?.commit.map { "Commit · \($0.shortID)" } ?? "Last commit"
        }
        return "Working tree on \(repository?.branch ?? "HEAD")"
    }
    var repositoryEmptyTitle: String {
        if repositoryReviewMode == .lastCommit {
            if repository?.head == nil { return "No commits yet" }
            return repository?.changes.isEmpty == true ? "This commit has no file changes" : "Select a committed file"
        }
        return repository?.changes.isEmpty == true ? "Working tree is clean" : "Select a changed file"
    }
    var repositoryReviewDescription: String {
        if repositoryReviewMode == .lastCommit {
            guard let commit = repository?.commit else { return "There is no commit to review yet." }
            if commit.parents.isEmpty { return "Initial commit · Compared with an empty base" }
            return commit.parents.count > 1 ? "Merge commit · Compared with its first parent" : "Committed changes relative to the parent"
        }
        return "Choose a baseline above, then select a working-change file to compare."
    }
    func repositoryChangeDescription(_ change: GitChange) -> String {
        repositoryReviewMode == .lastCommit ? "Committed change" : change.stagingDescription
    }

    private var comparisonGeneration = UUID()
    private var comparisonTask: Task<Void, Never>?
    private var comparisonWorker: Task<Comparison, Never>?
    private var leftLoadGeneration = UUID()
    private var rightLoadGeneration = UUID()
    private var leftLoadTask: Task<Void, Never>?
    private var rightLoadTask: Task<Void, Never>?
    private var pairLoadTask: Task<Void, Never>?

    var hasBothInputs: Bool { hasLeft && hasRight }
    var selectedRowID: Int? {
        guard let selectedChange, changeStarts.indices.contains(selectedChange) else { return nil }
        return rows[changeStarts[selectedChange]].id
    }

    deinit {
        repositoryTask?.cancel()
        repositoryFileTask?.cancel()
        repositoryBaselineTask?.cancel()
        comparisonTask?.cancel()
        comparisonWorker?.cancel()
        leftLoadTask?.cancel()
        rightLoadTask?.cancel()
        pairLoadTask?.cancel()
    }

    func setText(_ text: String, onLeft: Bool) {
        do { try updateText(text, onLeft: onLeft) } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Editors handle validation errors locally so rejected drafts stay available.
    func updateText(_ text: String, onLeft: Bool) throws {
        try TextFileReader.validate(text)
        closeRepository()
        cancelLoad(onLeft: onLeft)
        if onLeft {
            guard text != leftText || !hasLeft || leftURL != nil else { return }
            leftText = text
            leftURL = nil
            hasLeft = true
        } else {
            guard text != rightText || !hasRight || rightURL != nil else { return }
            rightText = text
            rightURL = nil
            hasRight = true
        }
        scheduleComparison()
    }

    func load(_ url: URL, onLeft: Bool) {
        closeRepository()
        cancelLoad(onLeft: onLeft)
        let generation = onLeft ? leftLoadGeneration : rightLoadGeneration
        if onLeft { isLoadingLeft = true } else { isLoadingRight = true }
        let task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try TextFileReader.read(url) }
            do {
                let text = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, let self, self.loadIsCurrent(generation, onLeft: onLeft) else { return }
                if onLeft {
                    self.leftText = text
                    self.leftURL = url
                    self.hasLeft = true
                } else {
                    self.rightText = text
                    self.rightURL = url
                    self.hasRight = true
                }
                self.finishLoad(onLeft: onLeft)
                self.scheduleComparison()
            } catch {
                guard !Task.isCancelled, let self, self.loadIsCurrent(generation, onLeft: onLeft) else { return }
                self.finishLoad(onLeft: onLeft)
                self.errorMessage = "Couldn’t open \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if onLeft { leftLoadTask = task } else { rightLoadTask = task }
    }

    func replaceComparison(original: URL, changed: URL) {
        closeRepository()
        cancelLoad(onLeft: true)
        cancelLoad(onLeft: false)
        errorMessage = nil
        isLoadingLeft = true
        isLoadingRight = true
        let leftGeneration = leftLoadGeneration
        let rightGeneration = rightLoadGeneration
        pairLoadTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                let left = try readComparisonInput(original)
                try Task.checkCancellation()
                let right = try readComparisonInput(changed)
                return (left, right)
            }
            do {
                let (left, right) = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, let self,
                      self.loadIsCurrent(leftGeneration, onLeft: true),
                      self.loadIsCurrent(rightGeneration, onLeft: false) else { return }
                self.finishPairLoad()
                // Publish neither side until the entire replacement has validated.
                self.leftText = left
                self.rightText = right
                self.leftURL = original
                self.rightURL = changed
                self.hasLeft = true
                self.hasRight = true
                self.scheduleComparison()
            } catch {
                guard !Task.isCancelled, let self,
                      self.loadIsCurrent(leftGeneration, onLeft: true),
                      self.loadIsCurrent(rightGeneration, onLeft: false) else { return }
                self.finishPairLoad()
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func swap() {
        closeRepository()
        cancelLoad(onLeft: true)
        cancelLoad(onLeft: false)
        (leftText, rightText) = (rightText, leftText)
        (leftURL, rightURL) = (rightURL, leftURL)
        (hasLeft, hasRight) = (hasRight, hasLeft)
        scheduleComparison()
    }

    func clear() {
        closeRepository()
        clearInputs()
    }

    private func clearInputs() {
        cancelLoad(onLeft: true)
        cancelLoad(onLeft: false)
        leftText = ""
        rightText = ""
        leftURL = nil
        rightURL = nil
        hasLeft = false
        hasRight = false
        errorMessage = nil
        scheduleComparison()
    }

    func clear(onLeft: Bool) {
        closeRepository()
        cancelLoad(onLeft: onLeft)
        if onLeft {
            leftText = ""
            leftURL = nil
            hasLeft = false
        } else {
            rightText = ""
            rightURL = nil
            hasRight = false
        }
        scheduleComparison()
    }

    func openRepository(_ url: URL) {
        closeRepository()
        repositoryURL = url
        refreshRepository()
    }

    func refreshRepository() {
        guard let url = repositoryURL else { return }
        repositoryTask?.cancel()
        repositoryFileTask?.cancel()
        cancelRepositoryBaselineCheck()
        repositoryGeneration = UUID()
        repositoryFileGeneration = UUID()
        let generation = repositoryGeneration
        let previousPath = selectedRepositoryPath
        let mode = repositoryReviewMode
        isScanningRepository = true
        isLoadingRepositoryFile = false
        repositoryMessage = nil
        selectedRepositoryFileIsIdentical = false
        clearInputs()
        repositoryTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try GitRepository.scan(url, mode: mode) }
            do {
                let snapshot = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self, self.repositoryGeneration == generation else { return }
                self.repository = snapshot
                self.repositoryURL = snapshot.root
                self.isScanningRepository = false
                self.repositoryTask = nil
                if mode == .workingChanges, let ref = self.repositoryBaselineRef, !snapshot.branches.contains(where: { $0.id == ref }) {
                    self.repositoryBaselineRef = nil
                    self.repositoryBaselineNotice = "The comparison branch is no longer available. Comparing against \(self.repositoryBaselineLabel)."
                }
                self.checkRepositoryBaseline()
                let path = snapshot.changes.first { $0.path == previousPath }?.path ?? snapshot.changes.first?.path
                self.selectRepositoryPath(path)
            } catch {
                guard !Task.isCancelled, let self, self.repositoryGeneration == generation else { return }
                self.isScanningRepository = false
                self.repositoryTask = nil
                self.repository = nil
                self.selectedRepositoryPath = nil
                self.repositoryMessage = error.localizedDescription
            }
        }
    }

    func selectRepositoryReviewMode(_ mode: GitReviewMode) {
        guard isRepositoryMode, mode != repositoryReviewMode else { return }
        repositoryReviewMode = mode
        repository = nil
        refreshRepository()
    }

    func selectRepositoryPath(_ path: String?) {
        repositoryFileTask?.cancel()
        repositoryFileGeneration = UUID()
        let generation = repositoryFileGeneration
        selectedRepositoryPath = path
        selectedRepositoryFileIsIdentical = false
        repositoryMessage = nil
        isLoadingRepositoryFile = false
        clearInputs()
        guard let repository, let change = repository.changes.first(where: { $0.path == path }) else { return }
        let baseline = repositoryBaseline
        identicalRepositoryPaths.remove(change.path)
        isLoadingRepositoryFile = true
        repositoryFileTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try GitRepository.comparison(for: change, in: repository, baseline: baseline)
            }
            do {
                let pair = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self, self.repositoryFileGeneration == generation else { return }
                self.isLoadingRepositoryFile = false
                self.repositoryFileTask = nil
                self.leftText = pair.original
                self.rightText = pair.changed
                self.hasLeft = true
                self.hasRight = true
                self.selectedRepositoryFileIsIdentical = baseline != nil && pair.isIdentical
                if self.selectedRepositoryFileIsIdentical {
                    self.identicalRepositoryPaths.insert(change.path)
                } else {
                    self.identicalRepositoryPaths.remove(change.path)
                }
                self.scheduleComparison()
            } catch {
                guard !Task.isCancelled, let self, self.repositoryFileGeneration == generation else { return }
                self.isLoadingRepositoryFile = false
                self.repositoryFileTask = nil
                self.repositoryMessage = error.localizedDescription
                self.identicalRepositoryPaths.remove(change.path)
            }
        }
    }

    func selectRepositoryBaseline(_ ref: String?) {
        guard repositoryReviewMode == .workingChanges, !isScanningRepository, ref != repositoryBaselineRef,
              ref == nil || repository?.branches.contains(where: { $0.id == ref }) == true else { return }
        repositoryBaselineRef = ref
        repositoryBaselineNotice = nil
        checkRepositoryBaseline()
        selectRepositoryPath(selectedRepositoryPath)
    }

    private func cancelRepositoryBaselineCheck() {
        repositoryBaselineTask?.cancel()
        repositoryBaselineTask = nil
        repositoryBaselineGeneration = UUID()
        identicalRepositoryPaths = []
        isCheckingRepositoryBaseline = false
    }

    private func checkRepositoryBaseline() {
        cancelRepositoryBaselineCheck()
        guard let repository, let baseline = repositoryBaseline, !repository.changes.isEmpty else { return }
        let generation = repositoryBaselineGeneration
        isCheckingRepositoryBaseline = true
        repositoryBaselineTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                var identical: Set<String> = []
                for change in repository.changes {
                    try Task.checkCancellation()
                    // Unsupported files stay listed and show their explanation when selected.
                    if let pair = try? GitRepository.comparison(for: change, in: repository, baseline: baseline), pair.isIdentical {
                        identical.insert(change.path)
                    }
                }
                return identical
            }
            let matches = try? await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.repositoryBaselineGeneration == generation else { return }
            self.identicalRepositoryPaths = matches ?? []
            // The selected file may have been read more recently than the background pass.
            if let path = self.selectedRepositoryPath, !self.isLoadingRepositoryFile {
                if self.selectedRepositoryFileIsIdentical {
                    self.identicalRepositoryPaths.insert(path)
                } else {
                    self.identicalRepositoryPaths.remove(path)
                }
            }
            self.isCheckingRepositoryBaseline = false
            self.repositoryBaselineTask = nil
        }
    }

    private func closeRepository() {
        repositoryTask?.cancel()
        repositoryFileTask?.cancel()
        cancelRepositoryBaselineCheck()
        repositoryTask = nil
        repositoryFileTask = nil
        repositoryGeneration = UUID()
        repositoryFileGeneration = UUID()
        repository = nil
        repositoryReviewMode = .workingChanges
        repositoryURL = nil
        selectedRepositoryPath = nil
        isScanningRepository = false
        isLoadingRepositoryFile = false
        repositoryMessage = nil
        repositoryBaselineRef = nil
        repositoryBaselineNotice = nil
        selectedRepositoryFileIsIdentical = false
    }

    func moveChange(_ delta: Int) {
        guard !changeStarts.isEmpty, !isComparing else { return }
        let count = changeStarts.count
        let start = selectedChange ?? (delta >= 0 ? -1 : 0)
        selectedChange = ((start + delta % count) % count + count) % count
    }

    private func scheduleComparison() {
        comparisonTask?.cancel()
        comparisonWorker?.cancel()
        comparisonTask = nil
        comparisonWorker = nil
        comparisonGeneration = UUID()
        rows = []
        changeStarts = []
        selectedChange = nil
        addedCount = 0
        removedCount = 0
        modifiedCount = 0
        longestLineCharacterCount = 0
        isComparing = hasBothInputs
        guard hasBothInputs else { return }

        let generation = comparisonGeneration
        let left = leftText
        let right = rightText
        let ignoringWhitespace = ignoreWhitespace
        comparisonTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, self.comparisonGeneration == generation else { return }
            let worker = Task.detached(priority: .userInitiated) {
                Comparison(rows: DiffEngine.compare(left, right, ignoringWhitespace: ignoringWhitespace))
            }
            self.comparisonWorker = worker
            let result = await worker.value
            guard !Task.isCancelled, self.comparisonGeneration == generation else { return }
            self.rows = result.rows
            self.changeStarts = result.changeStarts
            self.addedCount = result.addedCount
            self.removedCount = result.removedCount
            self.modifiedCount = result.modifiedCount
            self.longestLineCharacterCount = result.longestLineCharacterCount
            self.selectedChange = result.changeStarts.isEmpty ? nil : 0
            self.isComparing = false
            self.comparisonTask = nil
            self.comparisonWorker = nil
        }
    }

    private func cancelLoad(onLeft: Bool) {
        // A manual change to either side supersedes the whole pending handoff.
        if let pairLoadTask {
            pairLoadTask.cancel()
            finishPairLoad()
        }
        if onLeft {
            leftLoadTask?.cancel()
            leftLoadGeneration = UUID()
        } else {
            rightLoadTask?.cancel()
            rightLoadGeneration = UUID()
        }
        finishLoad(onLeft: onLeft)
    }

    private func finishPairLoad() {
        pairLoadTask = nil
        isLoadingLeft = false
        isLoadingRight = false
    }

    private func finishLoad(onLeft: Bool) {
        if onLeft {
            isLoadingLeft = false
            leftLoadTask = nil
        } else {
            isLoadingRight = false
            rightLoadTask = nil
        }
    }

    private func loadIsCurrent(_ generation: UUID, onLeft: Bool) -> Bool {
        generation == (onLeft ? leftLoadGeneration : rightLoadGeneration)
    }
}

private struct ComparisonInputError: LocalizedError {
    let errorDescription: String?
}

private func readComparisonInput(_ url: URL) throws -> String {
    do {
        return try TextFileReader.read(url)
    } catch {
        throw ComparisonInputError(errorDescription: "Couldn’t open \(url.lastPathComponent): \(error.localizedDescription)")
    }
}

private struct Comparison: Sendable {
    let rows: [DiffRow]
    var changeStarts: [Int] = []
    var addedCount = 0
    var removedCount = 0
    var modifiedCount = 0
    var longestLineCharacterCount = 0

    init(rows: [DiffRow]) {
        self.rows = rows
        var previousWasChanged = false
        for (index, row) in rows.enumerated() {
            if Task.isCancelled { return }
            let isChanged = row.kind != .unchanged
            if isChanged && !previousWasChanged { changeStarts.append(index) }
            previousWasChanged = isChanged
            switch row.kind {
            case .added: addedCount += 1
            case .removed: removedCount += 1
            case .modified: modifiedCount += 1
            case .unchanged: break
            }
            for text in [row.oldText, row.newText].compactMap({ $0 }) {
                let width = text.reduce(into: 0) { $0 += TextFileReader.displayColumns(for: $1) }
                longestLineCharacterCount = max(longestLineCharacterCount, width)
            }
        }
    }
}
#endif
