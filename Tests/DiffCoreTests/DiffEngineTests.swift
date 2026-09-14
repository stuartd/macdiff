import Testing
@testable import DiffCore

@Test func identicalFiles() {
    let rows = DiffEngine.compare("one\ntwo", "one\ntwo")
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0.kind == .unchanged })
}

@Test func alignsModification() {
    let rows = DiffEngine.compare("one\nold\nthree", "one\nnew\nthree")
    #expect(rows.count == 3)
    #expect(rows[1].kind == .modified)
    #expect(rows[1].oldNumber == 2)
    #expect(rows[1].newNumber == 2)
}

@Test func handlesInsertionsAndDeletions() {
    let rows = DiffEngine.compare("keep\nremove", "keep\nadd\nmore")
    #expect(rows.map(\.kind) == [.unchanged, .modified, .added])
    #expect(rows[2].oldNumber == nil)
    #expect(rows[2].newNumber == 3)
}

@Test func optionallyIgnoresWhitespace() {
    let exact = DiffEngine.compare("let x = 1", "let   x = 1")
    let relaxed = DiffEngine.compare("let x = 1", "let   x = 1", ignoringWhitespace: true)
    #expect(exact[0].kind == .modified)
    #expect(relaxed[0].kind == .unchanged)
}
