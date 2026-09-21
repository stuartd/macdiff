import Foundation
import Testing
@testable import DiffCore

@Test(arguments: [
    ("/dir4/dir1/dir2/index.html", "/dir5/dir3/dir2/index.html", "dir1/dir2/index.html", "dir3/dir2/index.html"),
    ("/original/index.html", "/changed/index.html", "original/index.html", "changed/index.html"),
    ("/original/first.html", "/changed/second.html", "first.html", "second.html"),
    ("/dir/index.html", "/outer/dir/index.html", "/dir/index.html", "outer/dir/index.html"),
    ("/index.html", "/dir/index.html", "/index.html", "dir/index.html"),
    ("/same/index.html", "/same/index.html", "index.html", "index.html"),
    ("/a/../same/index.html", "/same/index.html", "index.html", "index.html"),
    ("/before α/index.html", "/after 日本語/index.html", "before α/index.html", "after 日本語/index.html")
])
func fileLabelsDistinguishPaths(paths: (String, String, String, String)) {
    let left = URL(fileURLWithPath: paths.0)
    let right = URL(fileURLWithPath: paths.1)
    #expect(FilePathLabel.title(for: left, comparedWith: right) == paths.2)
    #expect(FilePathLabel.title(for: right, comparedWith: left) == paths.3)
}

@Test func singleFileLabelUsesFilename() {
    #expect(FilePathLabel.title(for: URL(fileURLWithPath: "/dir/index.html"), comparedWith: nil) == "index.html")
}

@Test func clipDiffClipboardLabelsHideTransportFilenames() {
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipDiff/External Comparisons/\(UUID().uuidString)")
    for side in ["Previous", "Current"] {
        let url = workspace.appendingPathComponent("\(side) clipboard.txt")
        #expect(FilePathLabel.title(for: url, comparedWith: nil) == "\(side) clipboard")
        let realFile = workspace.appendingPathComponent("\(side)/\(side) clipboard.txt")
        #expect(FilePathLabel.title(for: realFile, comparedWith: nil) == "\(side) clipboard.txt")
    }
    let ordinaryFile = URL(fileURLWithPath: "/documents/Current clipboard.txt")
    #expect(FilePathLabel.title(for: ordinaryFile, comparedWith: nil) == "Current clipboard.txt")
}
