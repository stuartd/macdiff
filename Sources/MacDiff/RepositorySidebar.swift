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
    @State private var changes: [GitChange] = []
    @State private var tree: [PathNode] = []
    @AppStorage("repositoryTreeView") private var showsTree = false

    private func refreshPaths() {
        changes = (document.repository?.changes ?? []).filter {
            filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter)
        }
        tree = PathNode.tree(changes)
    }
    private var selection: Binding<String?> {
        Binding(get: { document.selectedRepositoryPath }, set: { document.selectRepositoryPath($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label(document.repositoryURL?.lastPathComponent ?? "Repository", systemImage: "folder")
                    .font(AppTypography.heading).lineLimit(1).truncationMode(.middle)
                    .help(document.repositoryURL?.path ?? "")
                HStack {
                    Text(document.repository?.branch ?? "Repository").lineLimit(1)
                    Spacer()
                    Text("\(document.repository?.changes.count ?? 0) files").monospacedDigit()
                }
                .font(AppTypography.body).foregroundStyle(.secondary)
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
                    OutlineGroup(tree, children: \.children) { node in
                        if let change = node.change {
                            changeRow(change, showParent: false).tag(change.path)
                        } else {
                            HStack {
                                Label(node.name, systemImage: "folder")
                                Spacer()
                                Text("\(node.fileCount)").foregroundStyle(.secondary)
                            }
                            .font(AppTypography.body)
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
            VStack(alignment: .leading, spacing: 8) {
                Text("\(document.repositoryBaselineLabel) → \(document.repositoryTargetLabel)").fontWeight(.medium)
                Text("Read-only · ⌘R to refresh").foregroundStyle(.secondary)
            }
            .font(AppTypography.body)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
        }
        .font(AppTypography.body)
        .background(.bar)
        .onAppear(perform: refreshPaths)
        .onChange(of: filter) { _, _ in refreshPaths() }
        .onChange(of: document.repository?.changes) { _, _ in refreshPaths() }
        .onChange(of: document.repositoryURL) { _, _ in filter = ""; refreshPaths() }
        .onChange(of: document.repository?.commit?.id) { _, _ in filter = ""; refreshPaths() }
    }

    private func changeRow(_ change: GitChange, showParent: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text((change.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                if showParent && change.path.contains("/") {
                    Text((change.path as NSString).deletingLastPathComponent)
                        .font(AppTypography.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 2)
            Text(String(change.status.prefix(1)))
                .font(AppTypography.body.monospaced().weight(.semibold))
                .foregroundStyle(change.status == "Deleted" ? Color.red : change.status == "Added" ? .green : .orange)
                .help(change.status)
        }
        .padding(.vertical, 4)
        .help("\(change.path)\n\(change.status) · Committed change")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(change.path), \(change.status), Committed change")
    }
}

struct PathNode: Identifiable {
    let id: String
    let name: String
    var change: GitChange?
    var children: [PathNode]?
    let fileCount: Int

    private struct Entry {
        let change: GitChange
        let components: [String]
    }

    static func tree(_ changes: [GitChange]) -> [PathNode] {
        tree(changes.map { Entry(change: $0, components: ($0.path as NSString).pathComponents) }, depth: 0)
    }

    private static func tree(_ entries: [Entry], depth: Int) -> [PathNode] {
        let groups = Dictionary(grouping: entries) { $0.components[depth] }
        return groups.map { name, entries in
            let path = entries[0].components.prefix(depth + 1).joined(separator: "/")
            let file = entries.first { $0.components.count == depth + 1 }?.change
            let descendants = entries.filter { $0.components.count > depth + 1 }
            let children = descendants.isEmpty ? nil : tree(descendants, depth: depth + 1)
            let count = (file == nil ? 0 : 1) + (children ?? []).reduce(0) { $0 + $1.fileCount }
            return PathNode(id: path, name: name, change: file, children: children, fileCount: count)
        }
        .sorted {
            if ($0.children != nil) != ($1.children != nil) { return $0.children != nil }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
#endif
