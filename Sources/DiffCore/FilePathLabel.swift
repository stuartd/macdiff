import Foundation

public enum FilePathLabel {
    /// Include the first differing ancestor when filenames alone are ambiguous.
    public static func title(for url: URL, comparedWith other: URL?) -> String {
        if let clipboardTitle = clipboardTitle(for: url) { return clipboardTitle }
        guard let other else { return url.lastPathComponent }
        let path = url.standardizedFileURL
        let otherPath = other.standardizedFileURL
        guard path.path != otherPath.path else { return path.lastPathComponent }

        let components = path.pathComponents
        let otherComponents = otherPath.pathComponents
        let sharedCount = zip(components.reversed(), otherComponents.reversed())
            .prefix(while: { $0.0 == $0.1 }).count
        let count = sharedCount + 1
        // Preserve the leading slash when the distinguishing ancestor is the root.
        if count >= components.count { return path.path }
        return components.suffix(count).joined(separator: "/")
    }

    public static func clipboardTitle(for url: URL) -> String? {
        // ClipDiff writes unnamed clipboard inputs directly into a UUID workspace.
        // Named source files go in a side subfolder and retain their real names.
        let directory = url.standardizedFileURL.deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipDiff/External Comparisons", isDirectory: true)
        guard UUID(uuidString: directory.lastPathComponent) != nil,
              directory.deletingLastPathComponent().resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path else {
            return nil
        }
        switch url.lastPathComponent {
        case "Previous clipboard.txt": return "Previous clipboard"
        case "Current clipboard.txt": return "Current clipboard"
        default: return nil
        }
    }
}
