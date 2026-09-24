#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DiffCore

struct ContentView: View {
    @ObservedObject var document: DiffDocument
    @State private var choosingLeft = true
    @State private var showingImporter = false
    @State private var importDirectory = URL.documentsDirectory
    @State private var editorInput: EditorInput?
    @State private var loadedLaunchInputs = false
    @AppStorage("diffFontSize") private var fontSize = 13.0
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if document.isRepositoryMode {
                    RepositorySidebar(document: document)
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 300)
                    Divider()
                }
                comparisonPane
            }
            Divider()
            statusBar
        }
        .background(Color(nsColor: .textBackgroundColor))
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .toolbar { windowToolbar }
        .focusedSceneValue(\.comparisonActions, ComparisonActions(
            open: open, paste: paste, edit: edit, copy: copy,
            canChangeInputs: !document.isRepositoryMode && editorInput == nil && !showingImporter
        ))
        .task { loadLaunchInputs() }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case let .success(url):
                importDirectory = url.deletingLastPathComponent()
                document.load(url, onLeft: choosingLeft)
            case let .failure(error):
                if (error as NSError).code != NSUserCancelledError {
                    document.errorMessage = error.localizedDescription
                }
            }
        }
        .fileDialogDefaultDirectory(importDirectory)
        .alert("Unable to use this input", isPresented: Binding(
            get: { document.errorMessage != nil },
            set: { if !$0 { document.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { document.errorMessage = nil }
        } message: {
            Text(document.errorMessage ?? "")
        }
        .sheet(item: $editorInput) { input in
            TextInputEditor(input: input) { text in
                try document.updateText(text, onLeft: input.onLeft)
            }
        }
    }

    private var comparisonPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if document.isRepositoryMode {
                    repositoryHeader(onLeft: true)
                    Divider()
                    repositoryHeader(onLeft: false)
                } else {
                    sourceHeader(onLeft: true)
                    Divider()
                    sourceHeader(onLeft: false)
                }
            }
            .frame(height: 74)
            Divider()
            GeometryReader { geometry in
                Group {
                    if document.isScanningRepository {
                        ProgressView("Reading repository…")
                    } else if document.isLoadingRepositoryFile {
                        ProgressView("Reading file…")
                    } else if let message = document.repositoryMessage {
                        ContentUnavailableView("Unable to show comparison", systemImage: "doc.badge.ellipsis", description: Text(message))
                    } else if document.hasBothInputs {
                        diffView
                    } else if document.isRepositoryMode {
                        ContentUnavailableView(
                            document.repository?.changes.isEmpty == true ? "Working tree is clean" : "Select a changed file",
                            systemImage: document.repository?.changes.isEmpty == true ? "checkmark.circle" : "doc.text.magnifyingglass",
                            description: Text("Compare the last commit with the files in your working tree."))
                    } else {
                        welcome
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .dropDestination(for: URL.self) { urls, location in
                    loadDroppedFile(urls, onLeft: location.x < geometry.size.width / 2)
                }
            }
        }
    }

    private func repositoryHeader(onLeft: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(onLeft ? (document.repository?.head == nil ? "EMPTY BASE" : "LAST COMMIT") : "WORKING TREE")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { copy(onLeft: onLeft) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .disabled(!document.hasBothInputs)
                    .help(onLeft ? "Copy committed text" : "Copy working-tree text")
            }
            Text((onLeft ? document.selectedRepositoryChange?.originalPath : nil) ?? document.selectedRepositoryPath ?? "No file selected")
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
                .help(document.selectedRepositoryPath ?? "")
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                Button("Open Original…") { open(onLeft: true) }
                    .disabled(document.isRepositoryMode)
                Button("Open Changed…") { open(onLeft: false) }
                    .disabled(document.isRepositoryMode)
                Divider()
                Button("Open Repository…") { document.chooseRepository() }
            } label: {
                Label("Open", systemImage: "folder")
            }
            .accessibilityLabel("Open")
            .help("Open files or a Git repository")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if document.isRepositoryMode {
                Button { document.refreshRepository() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(document.isScanningRepository)
                .help("Refresh repository (⌘R)")
            }
            Button { document.moveChange(-1) } label: {
                Label("Previous Change", systemImage: "chevron.up")
            }
            .help("Previous group of changes (⌘[)")
            .disabled(document.changeStarts.isEmpty || document.isComparing)
            Button { document.moveChange(1) } label: {
                Label("Next Change", systemImage: "chevron.down")
            }
            .help("Next group of changes (⌘])")
            .disabled(document.changeStarts.isEmpty || document.isComparing)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Toggle("Ignore Spacing", isOn: $document.ignoreWhitespace)
                Button("Swap Inputs") { document.swap() }
                    .disabled(document.isRepositoryMode || (!document.hasLeft && !document.hasRight))
            } label: {
                Label("Comparison Options", systemImage: document.ignoreWhitespace ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Comparison Options")
            .help(document.ignoreWhitespace ? "Comparison options · Ignoring spacing" : "Comparison options")
        }
    }

    private func sourceHeader(onLeft: Bool) -> some View {
        let url = onLeft ? document.leftURL : document.rightURL
        let hasInput = onLeft ? document.hasLeft : document.hasRight
        let isLoading = onLeft ? document.isLoadingLeft : document.isLoadingRight
        let title = onLeft ? "Original" : "Changed"
        let otherURL = onLeft ? document.rightURL : document.leftURL
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(url.map { FilePathLabel.title(for: $0, comparedWith: otherURL) } ?? (hasInput ? "Text input" : "No input"))
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                    .help(url.map { FilePathLabel.clipboardTitle(for: $0) ?? $0.path } ?? title)
            }
            Spacer(minLength: 0)
            if isLoading {
                ProgressView().controlSize(.small).accessibilityLabel("Loading \(title.lowercased())")
            }
            Menu {
                Button("Open File…") { open(onLeft: onLeft) }
                Button("Paste Text") { paste(onLeft: onLeft) }
                Button("Edit Text…") { edit(onLeft: onLeft) }
                Divider()
                Button("Copy Text") { copy(onLeft: onLeft) }.disabled(!hasInput)
                Button("Clear Input") { document.clear(onLeft: onLeft) }.disabled(!hasInput && !isLoading)
            } label: {
                Label("\(title) input actions", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Open, paste, edit, or copy \(title.lowercased()) text")
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            loadDroppedFile(urls, onLeft: onLeft)
        }
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 20)
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 42, weight: .light)).foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Compare two versions").font(.title2.weight(.semibold))
                Text("Add an original and a changed version to see what’s different.")
                    .foregroundStyle(.secondary)
                Text("Open two files, drop them onto either text pane, or paste text from the clipboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 20) {
                inputCard(onLeft: true)
                inputCard(onLeft: false)
            }
            .padding(.horizontal, 36)
            .frame(maxWidth: 1000)
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inputCard(onLeft: Bool) -> some View {
        let hasInput = onLeft ? document.hasLeft : document.hasRight
        let text = onLeft ? document.leftText : document.rightText
        return VStack(alignment: .leading, spacing: 12) {
            Label(onLeft ? "Original" : "Changed", systemImage: hasInput ? "checkmark.circle.fill" : "circle.dashed")
                .font(.headline).foregroundStyle(hasInput ? Color.accentColor : .secondary)
            if hasInput {
                Text(text.isEmpty ? "Empty text" : String(text.prefix(1200)))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(7)
                    .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 110, alignment: .topLeading)
                Button("Edit text…") { edit(onLeft: onLeft) }
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 110)
                    .accessibilityHidden(true)
                Button("Paste \(onLeft ? "Original" : "Changed")") { paste(onLeft: onLeft) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var diffView: some View {
        GeometryReader { geometry in
            let paneWidth = max(0, (geometry.size.width - 1) / 2)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(document.rows) { row in
                            DiffRowView(row: row, paneWidth: paneWidth, fontSize: fontSize, selected: row.id == document.selectedRowID)
                                .id(row.id)
                        }
                    }
                    .frame(width: paneWidth * 2 + 1, alignment: .topLeading)
                }
                .onChange(of: document.selectedRowID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: document.isComparing) { _, comparing in
                    if !comparing, let id = document.selectedRowID { proxy.scrollTo(id, anchor: .center) }
                }
                .overlay {
                    if document.isComparing {
                        ProgressView("Comparing…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    } else if document.rows.isEmpty {
                        ContentUnavailableView("Both inputs are empty", systemImage: "equal.circle", description: Text(document.isRepositoryMode ? "Git may be reporting a rename or a file mode change." : "Paste or edit either side to compare text."))
                    }
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            if document.hasBothInputs && !document.isComparing {
                Label("\(document.addedCount) added", systemImage: "plus").foregroundStyle(.green)
                Label("\(document.removedCount) removed", systemImage: "minus").foregroundStyle(.red)
                Label("\(document.modifiedCount) changed", systemImage: "pencil").foregroundStyle(.orange)
            }
            Spacer()
            Text(statusText).foregroundStyle(.secondary)
        }
        .font(.caption).padding(.horizontal, 16).frame(height: 30).background(.bar)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if document.isScanningRepository { return "Reading repository…" }
        if document.isLoadingRepositoryFile { return "Reading file…" }
        if document.repositoryMessage != nil { return "Comparison unavailable" }
        if document.isRepositoryMode && !document.hasBothInputs { return "\(document.repository?.changes.count ?? 0) changed files" }
        if document.isLoadingLeft || document.isLoadingRight { return "Loading text…" }
        if !document.hasLeft && !document.hasRight { return "Add two inputs to begin" }
        if !document.hasLeft { return "Add the original text" }
        if !document.hasRight { return "Add the changed text" }
        if document.isComparing { return "Comparing…" }
        if document.changeStarts.isEmpty {
            return document.ignoreWhitespace ? "No differences ignoring spacing" : (document.isRepositoryMode ? "No text differences · Git status may reflect staging, a rename, or permissions" : "No differences")
        }
        return "Change \((document.selectedChange ?? 0) + 1) of \(document.changeStarts.count)"
    }

    private func loadLaunchInputs() {
        guard !loadedLaunchInputs else { return }
        loadedLaunchInputs = true
        do {
            let request = try LaunchRequest.parse(Array(CommandLine.arguments.dropFirst()), currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            switch request {
            case .empty: break
            case let .compare(original, changed):
                document.replaceComparison(original: original, changed: changed)
            case .help:
                print(LaunchRequest.usage)
                NSApp.terminate(nil)
            }
        } catch {
            document.errorMessage = error.localizedDescription
        }
    }

    private func open(onLeft: Bool) {
        choosingLeft = onLeft
        showingImporter = true
    }

    private func loadDroppedFile(_ urls: [URL], onLeft: Bool) -> Bool {
        guard !document.isRepositoryMode, urls.count == 1, let url = urls.first, url.isFileURL else { return false }
        document.load(url, onLeft: onLeft)
        return true
    }

    private func edit(onLeft: Bool) {
        editorInput = EditorInput(onLeft: onLeft, text: onLeft ? document.leftText : document.rightText)
    }

    private func paste(onLeft: Bool) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            document.errorMessage = "The clipboard doesn’t contain plain text. Copy some text and try again."
            return
        }
        document.setText(text, onLeft: onLeft)
    }

    private func copy(onLeft: Bool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(onLeft ? document.leftText : document.rightText, forType: .string)
    }
}

private struct EditorInput: Identifiable {
    let id = UUID()
    let onLeft: Bool
    let text: String
}

private struct TextInputEditor: View {
    let input: EditorInput
    let onSave: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draftText: String
    @State private var validationError: String?

    init(input: EditorInput, onSave: @escaping (String) throws -> Void) {
        self.input = input
        self.onSave = onSave
        _draftText = State(initialValue: input.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(input.onLeft ? "Original" : "Changed") text").font(.title2.weight(.semibold))
            Text("Paste or type plain text. You can also compare an empty input.").foregroundStyle(.secondary)
            TextEditor(text: $draftText)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
                .border(.quaternary)
                .accessibilityLabel("\(input.onLeft ? "Original" : "Changed") text editor")
            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Text") {
                    do {
                        try onSave(draftText)
                        dismiss()
                    } catch {
                        validationError = error.localizedDescription
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 720, height: 480)
    }

}

private struct DiffRowView: View {
    let row: DiffRow
    let paneWidth: CGFloat
    let fontSize: CGFloat
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            side(number: row.oldNumber, text: row.oldText, onLeft: true)
            Color.clear.frame(width: 1, height: 1)
            side(number: row.newNumber, text: row.newText, onLeft: false)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: fontSize + 12)
        .background {
            HStack(spacing: 0) {
                background(true).frame(width: paneWidth)
                Color(nsColor: .separatorColor).frame(width: 1)
                background(false).frame(width: paneWidth)
            }
        }
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Color.accentColor).frame(width: 3) }
        }
        .overlay {
            if selected { Rectangle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1) }
        }
    }

    private func side(number: Int?, text: String?, onLeft: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: max(52, fontSize * 3.9), alignment: .trailing)
                .padding(.trailing, 10)
            Text(marker(onLeft)).foregroundStyle(markerColor(onLeft)).frame(width: 18)
            Text(DiffTextFormatting.attributed(text ?? " ",
                highlights: onLeft ? row.oldHighlights : row.newHighlights,
                color: markerColor(onLeft)))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: fontSize, design: .monospaced))
        .padding(.vertical, 5)
        .padding(.trailing, 8)
        .frame(width: paneWidth, alignment: .topLeading)
    }

    private func marker(_ onLeft: Bool) -> String {
        switch row.kind {
        case .added: return onLeft ? "" : "+"
        case .removed: return onLeft ? "−" : ""
        case .modified: return onLeft ? "−" : "+"
        case .unchanged: return ""
        }
    }

    private func markerColor(_ onLeft: Bool) -> Color { onLeft ? .red : .green }

    private func background(_ onLeft: Bool) -> Color {
        switch row.kind {
        case .added: return onLeft ? .clear : .green.opacity(0.12)
        case .removed: return onLeft ? .red.opacity(0.12) : .clear
        case .modified: return onLeft ? .red.opacity(0.12) : .green.opacity(0.12)
        case .unchanged: return .clear
        }
    }
}
#endif
