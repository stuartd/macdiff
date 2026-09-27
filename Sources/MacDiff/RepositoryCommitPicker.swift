#if os(macOS)
import SwiftUI
import DiffCore

struct RepositoryCommitPicker: View {
    @ObservedObject var document: DiffDocument
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                Text(document.selectedRepositoryCommitID == nil ? "Last commit" : "Commit")
                if let commit = document.repository?.commit {
                    Text(commit.shortID).monospaced().foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down").font(.caption)
            }
        }
        .disabled(document.isScanningRepository || (document.repository?.head == nil && document.repositoryMessage == nil))
        .help("Browse commits or search by message or hash")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            if let repository = document.repository {
                CommitHistoryPicker(repository: repository, selectedID: document.selectedRepositoryCommitID) { id in
                    document.selectRepositoryCommit(id)
                    isPresented = false
                }
            } else {
                Button("Return to last commit") {
                    if document.selectedRepositoryCommitID == nil {
                        document.refreshRepository()
                    } else {
                        document.selectRepositoryCommit(nil)
                    }
                    isPresented = false
                }
                .padding(16)
            }
        }
    }
}

private struct CommitHistoryPicker: View {
    let repository: GitSnapshot
    let selectedID: String?
    let select: (String?) -> Void
    @State private var query = ""
    @State private var limit = 100
    @State private var commits: [GitCommit] = []
    @State private var isLoading = true
    @State private var hasMore = false
    @State private var errorMessage: String?
    @FocusState private var searchFocused: Bool

    private struct Request: Equatable {
        let query: String
        let limit: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browse commits").font(AppTypography.heading)
            TextField("Search messages or commit hash", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityLabel("Search commit history")
                .onChange(of: query) { _, _ in limit = 100 }
            Button { select(nil) } label: {
                HStack {
                    Text("Last commit on \(repository.branch)").lineLimit(1)
                    Spacer()
                    if selectedID == nil { Image(systemName: "checkmark") }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            if isLoading {
                ProgressView("Reading commits…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if commits.isEmpty {
                Text("No matching commits").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(commits) { commit in
                            Button { select(commit.id) } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(commit.subject).lineLimit(2).multilineTextAlignment(.leading)
                                        Text(commit.shortID).monospaced().foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedID == commit.id { Image(systemName: "checkmark") }
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("\(commit.id)\n\(commit.subject)")
                        }
                        if hasMore {
                            Button("Load more commits") { limit += 100 }
                                .frame(maxWidth: .infinity).padding(8)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 440, height: 420)
        .onAppear { searchFocused = true }
        .task(id: Request(query: query, limit: limit)) {
            isLoading = true
            errorMessage = nil
            do {
                try await Task.sleep(for: .milliseconds(200))
                let query = query
                let limit = limit
                let worker = Task.detached(priority: .userInitiated) {
                    try GitRepository.history(in: repository, query: query, limit: limit + 1)
                }
                let results = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                commits = Array(results.prefix(limit))
                hasMore = results.count > limit
                isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}
#endif
