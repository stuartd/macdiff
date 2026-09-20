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

    private var comparisonGeneration = UUID()
    private var comparisonTask: Task<Void, Never>?
    private var comparisonWorker: Task<Comparison, Never>?
    private var leftLoadGeneration = UUID()
    private var rightLoadGeneration = UUID()
    private var leftLoadTask: Task<Void, Never>?
    private var rightLoadTask: Task<Void, Never>?

    var hasBothInputs: Bool { hasLeft && hasRight }
    var selectedRowID: Int? {
        guard let selectedChange, changeStarts.indices.contains(selectedChange) else { return nil }
        return rows[changeStarts[selectedChange]].id
    }

    deinit {
        comparisonTask?.cancel()
        comparisonWorker?.cancel()
        leftLoadTask?.cancel()
        rightLoadTask?.cancel()
    }

    func setText(_ text: String, onLeft: Bool) {
        do { try TextFileReader.validate(text) } catch {
            errorMessage = error.localizedDescription
            return
        }
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
        clear()
        load(original, onLeft: true)
        load(changed, onLeft: false)
    }

    func swap() {
        cancelLoad(onLeft: true)
        cancelLoad(onLeft: false)
        (leftText, rightText) = (rightText, leftText)
        (leftURL, rightURL) = (rightURL, leftURL)
        (hasLeft, hasRight) = (hasRight, hasLeft)
        scheduleComparison()
    }

    func clear() {
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
        if onLeft {
            leftLoadTask?.cancel()
            leftLoadGeneration = UUID()
        } else {
            rightLoadTask?.cancel()
            rightLoadGeneration = UUID()
        }
        finishLoad(onLeft: onLeft)
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
