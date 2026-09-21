import Foundation

public enum FilePathLabel {
    /// Include the first differing ancestor when filenames alone are ambiguous.
    public static func title(for url: URL, comparedWith other: URL?) -> String {
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
}
