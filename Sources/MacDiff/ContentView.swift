#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import DiffCore

@MainActor
final class DiffDocument: ObservableObject {
    @Published var leftURL: URL?
    @Published var rightURL: URL?
    @Published var leftText = ""
    @Published var rightText = ""
    @Published var ignoreWhitespace = false
    @Published var selectedChange = 0

    var rows: [DiffRow] { DiffEngine.compare(leftText, rightText, ignoringWhitespace: ignoreWhitespace) }
    var changes: [Int] { rows.indices.filter { rows[$0].kind != .unchanged } }

    func load(_ url: URL, onLeft: Bool) {
        guard let value = try? String(contentsOf: url, encoding: .utf8) else { return }
        if onLeft { leftURL = url; leftText = value } else { rightURL = url; rightText = value }
        selectedChange = 0
    }

    func swap() {
        (leftURL, rightURL) = (rightURL, leftURL)
        (leftText, rightText) = (rightText, leftText)
        selectedChange = 0
    }

    func moveChange(_ delta: Int) {
        guard !changes.isEmpty else { return }
        selectedChange = (selectedChange + delta + changes.count) % changes.count
    }
}

struct ContentView: View {
    @StateObject private var document = DiffDocument()
    @State private var choosingLeft = true
    @State private var showingImporter = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.45)
            fileHeader
            if document.leftURL == nil && document.rightURL == nil {
                welcome
            } else {
                diffView
            }
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.plainText, .sourceCode, .data]) { result in
            if case let .success(url) = result { document.load(url, onLeft: choosingLeft) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.split.2x1").font(.title2).foregroundStyle(.mint)
            Text("MacDiff").font(.headline)
            Spacer()
            Button { document.moveChange(-1) } label: { Label("Previous", systemImage: "chevron.up") }
                .keyboardShortcut("[", modifiers: .command).disabled(document.changes.isEmpty)
            Button { document.moveChange(1) } label: { Label("Next", systemImage: "chevron.down") }
                .keyboardShortcut("]", modifiers: .command).disabled(document.changes.isEmpty)
            Divider().frame(height: 18)
            Toggle("Ignore whitespace", isOn: $document.ignoreWhitespace).toggleStyle(.switch).controlSize(.small)
            Button { document.swap() } label: { Label("Swap", systemImage: "arrow.left.arrow.right") }
                .disabled(document.leftURL == nil && document.rightURL == nil)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 18).frame(height: 52)
        .background(.ultraThinMaterial)
    }

    private var fileHeader: some View {
        HStack(spacing: 0) {
            fileButton(title: "Original", url: document.leftURL, isLeft: true)
            Divider()
            fileButton(title: "Changed", url: document.rightURL, isLeft: false)
        }
        .frame(height: 48)
    }

    private func fileButton(title: String, url: URL?, isLeft: Bool) -> some View {
        Button {
            choosingLeft = isLeft; showingImporter = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(url?.lastPathComponent ?? "Choose a file…").font(.system(.body, design: .monospaced)).lineLimit(1)
                }
                Spacer()
                Image(systemName: "folder").foregroundStyle(.secondary)
            }.padding(.horizontal, 16).contentShape(Rectangle())
        }.buttonStyle(.plain).frame(maxWidth: .infinity)
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "doc.on.doc").font(.system(size: 48, weight: .thin)).foregroundStyle(.secondary)
            Text("Compare two files").font(.title2.weight(.semibold))
            Text("Choose an original and changed file to see a side-by-side diff.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Original") { choosingLeft = true; showingImporter = true }
                Button("Open Changed") { choosingLeft = false; showingImporter = true }
            }.buttonStyle(.borderedProminent).tint(.mint)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var diffView: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: 0) {
                    ForEach(document.rows) { row in
                        DiffRowView(row: row).id(row.id)
                    }
                }.frame(minWidth: 900)
            }
            .onChange(of: document.selectedChange) { _, value in
                guard document.changes.indices.contains(value) else { return }
                withAnimation { proxy.scrollTo(document.rows[document.changes[value]].id, anchor: .center) }
            }
        }
    }

    private var statusBar: some View {
        let added = document.rows.filter { $0.kind == .added }.count
        let removed = document.rows.filter { $0.kind == .removed }.count
        let modified = document.rows.filter { $0.kind == .modified }.count
        return HStack(spacing: 14) {
            Label("\(added) added", systemImage: "plus").foregroundStyle(.green)
            Label("\(removed) removed", systemImage: "minus").foregroundStyle(.red)
            Label("\(modified) changed", systemImage: "pencil").foregroundStyle(.orange)
            Spacer()
            Text(document.changes.isEmpty ? "Files are identical" : "Change \(document.selectedChange + 1) of \(document.changes.count)")
                .foregroundStyle(.secondary)
        }.font(.caption).padding(.horizontal, 16).frame(height: 30).background(.ultraThinMaterial)
    }
}

private struct DiffRowView: View {
    let row: DiffRow
    var body: some View {
        HStack(spacing: 0) {
            side(number: row.oldNumber, text: row.oldText, isLeft: true)
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
            side(number: row.newNumber, text: row.newText, isLeft: false)
        }.frame(height: 24).background(background)
    }

    private func side(number: Int?, text: String?, isLeft: Bool) -> some View {
        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "").foregroundStyle(.tertiary).frame(width: 48, alignment: .trailing).padding(.trailing, 10)
            Text(marker(isLeft)).foregroundStyle(markerColor).frame(width: 18)
            Text(text ?? " ").foregroundStyle(text == nil ? .secondary : .primary).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
    }

    private func marker(_ isLeft: Bool) -> String {
        switch row.kind { case .added: return isLeft ? "" : "+"; case .removed: return isLeft ? "−" : ""; case .modified: return "~"; case .unchanged: return "" }
    }
    private var markerColor: Color { row.kind == .added ? .green : row.kind == .removed ? .red : .orange }
    private var background: Color {
        switch row.kind { case .added: return .green.opacity(0.12); case .removed: return .red.opacity(0.12); case .modified: return .orange.opacity(0.11); case .unchanged: return .clear }
    }
}
#endif
