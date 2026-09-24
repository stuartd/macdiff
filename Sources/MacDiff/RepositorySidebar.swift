#if os(macOS)
import AppKit
import SwiftUI
import DiffCore

extension DiffDocument {
    func chooseRepository() {
        guard !isChoosingRepository else { return }
        isChoosingRepository = true
        let panel = NSOpenPanel()
        panel.title = "Open Git Repository"
        panel.prompt = "Open Repository"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = repositoryURL
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.isChoosingRepository = false
            guard response == .OK, let url = panel.url else { return }
            self?.openRepository(url)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}

struct RepositorySidebar: View {
    @ObservedObject var document: DiffDocument
    @State private var filter = ""
    @AppStorage("repositoryTreeView") private var showsTree = false

    private var changes: [GitChange] {
        (document.repository?.changes ?? []).filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) }
    }
    private var selection: Binding<String?> {
        Binding(get: { document.selectedRepositoryPath }, set: { document.selectRepositoryPath($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label(document.repositoryURL?.lastPathComponent ?? "Repository", systemImage: "folder")
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                    .help(document.repositoryURL?.path ?? "")
                HStack {
                    Text(document.repository?.branch ?? "Repository").lineLimit(1)
                    Spacer()
                    Text("\(document.repository?.changes.count ?? 0) files").monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
                Picker("View", selection: $showsTree) {
                    Image(systemName: "list.bullet").tag(false).help("File list")
                    Image(systemName: "list.bullet.indent").tag(true).help("Directory tree")
                }
                .pickerStyle(.segmented)
                TextField("Filter paths", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter changed file paths")
            }
            .padding(12)
            Divider()
            List(selection: selection) {
                if showsTree {
                    OutlineGroup(PathNode.tree(changes), children: \.children) { node in
                        if let change = node.change {
                            changeRow(change, showParent: false).tag(change.path)
                        } else {
                            HStack {
                                Label(node.name, systemImage: "folder")
                                Spacer()
                                Text("\(node.fileCount)").foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                } else {
                    ForEach(changes) { change in
                        changeRow(change, showParent: true).tag(change.path)
                    }
                }
            }
            .listStyle(.sidebar)
            .disabled(document.isScanningRepository)
            .overlay {
                if !filter.isEmpty && changes.isEmpty {
                    Text("No matching paths").foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("Last commit → Working tree").fontWeight(.medium)
                Text(document.selectedRepositoryChange?.stagingDescription ?? "Includes staged, unstaged, and untracked files.")
                    .foregroundStyle(.secondary)
                Text("Read-only · ⌘R to refresh").foregroundStyle(.secondary)
            }
            .font(.caption).padding(12)
        }
        .background(.bar)
        .onChange(of: document.repositoryURL) { _, _ in filter = "" }
    }

    private func changeRow(_ change: GitChange, showParent: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text((change.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                if showParent && change.path.contains("/") {
                    Text((change.path as NSString).deletingLastPathComponent)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 2)
            Text(change.isUntracked ? "?" : String(change.status.prefix(1)))
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(change.isConflicted ? Color.red : change.status == "Deleted" ? .red : change.status == "Added" || change.isUntracked ? .green : .orange)
                .help(change.status)
        }
        .padding(.vertical, 2)
        .help("\(change.path)\n\(change.status) · \(change.stagingDescription)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(change.path), \(change.status), \(change.stagingDescription)")
    }
}

private struct PathNode: Identifiable {
    let id: String
    let name: String
    var change: GitChange?
    var children: [PathNode]?
    var fileCount: Int { change == nil ? (children ?? []).reduce(0) { $0 + $1.fileCount } : 1 }

    static func tree(_ changes: [GitChange], depth: Int = 0) -> [PathNode] {
        let groups = Dictionary(grouping: changes) { change in
            (change.path as NSString).pathComponents[depth]
        }
        return groups.map { name, entries in
            let components = (entries[0].path as NSString).pathComponents
            let path = components.prefix(depth + 1).joined(separator: "/")
            let file = entries.first { $0.path == path }
            let descendants = entries.filter { $0.path != path }
            return PathNode(id: path, name: name, change: file,
                            children: descendants.isEmpty ? nil : tree(descendants, depth: depth + 1))
        }.sorted {
            if ($0.children != nil) != ($1.children != nil) { return $0.children != nil }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
#endif
