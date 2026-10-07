#if os(macOS)
import Testing
@testable import DiffCore
@testable import MacDiff

@Test func directoryTreesRetainChangesAndCountNestedFiles() throws {
    let changes = [
        GitChange(path: "item", originalPath: nil, changeStatus: "D"),
        GitChange(path: "item/child", originalPath: nil, changeStatus: "A"),
        GitChange(path: "nested/deep/file", originalPath: nil, changeStatus: "M"),
        GitChange(path: "other", originalPath: nil, changeStatus: "M")
    ]
    let nodes = PathNode.tree(changes)
    #expect(nodes.reduce(0) { $0 + $1.fileCount } == changes.count)
    let item = try #require(nodes.first { $0.id == "item" })
    #expect(item.change?.changeStatus == "D")
    #expect(item.children?.first?.change?.path == "item/child")
    #expect(item.fileCount == 2)
    #expect(PathNode.tree([]).isEmpty)
}
#endif
