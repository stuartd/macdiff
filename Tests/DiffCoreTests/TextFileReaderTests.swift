import Foundation
import Testing
@testable import DiffCore

@Test func decodesUTF8AndStripsOnlyLeadingByteOrderMark() throws {
    #expect(try TextFileReader.decode(Data()) == "")
    #expect(try TextFileReader.decode(Data("Hello 🌍\n".utf8)) == "Hello 🌍\n")
    let data = Data([0xEF, 0xBB, 0xBF]) + Data("hello\u{FEFF}".utf8)
    #expect(try TextFileReader.decode(data) == "hello\u{FEFF}")
}

@Test func decodesBothUTF16ByteOrdersIncludingSurrogates() throws {
    let text = "Hello 🌍\r\nこんにちは"
    for (encoding, bom) in [(String.Encoding.utf16LittleEndian, [UInt8(0xFF), 0xFE]), (.utf16BigEndian, [0xFE, 0xFF])] {
        let data = Data(bom) + (text.data(using: encoding) ?? Data())
        #expect(try TextFileReader.decode(data) == text)
    }
    #expect(try TextFileReader.decode(Data([0xFF, 0xFE])) == "")
}

@Test func rejectsMalformedAndUnsupportedEncodingsWithoutReplacement() {
    for bytes: [UInt8] in [[0xC3, 0x28], [0xFF, 0xFE, 0x41], [0xFF, 0xFE, 0x00, 0xD8], [0xFE, 0xFF, 0xDC, 0x00], [0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00]] {
        #expect(throws: TextFileReader.ReadError.unsupportedEncoding) {
            try TextFileReader.decode(Data(bytes))
        }
    }
}

@Test func rejectsBinaryControlsButPreservesTextWhitespace() throws {
    #expect(throws: TextFileReader.ReadError.binaryContent) {
        try TextFileReader.decode(Data([0x41, 0x00, 0x42]))
    }
    #expect(throws: TextFileReader.ReadError.binaryContent) {
        try TextFileReader.decode(Data([0x01, 0x02, 0x03]))
    }
    #expect(try TextFileReader.decode(Data("a\tb\nc\r\nd\u{0C}".utf8)) == "a\tb\nc\r\nd\u{0C}")
}

@Test func enforcesMaximumInputBytes() {
    #expect(throws: TextFileReader.ReadError.tooLarge) {
        try TextFileReader.decode(Data(repeating: 0x41, count: TextFileReader.maximumByteCount + 1))
    }
}

@Test func readsFilesAndRejectsDirectories() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipdiff-\(UUID()).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("Example\n".utf8).write(to: url)
    #expect(try TextFileReader.read(url) == "Example\n")
    #expect(throws: TextFileReader.ReadError.notRegularFile) {
        try TextFileReader.read(FileManager.default.temporaryDirectory)
    }
}

@Test func boundsLineCountAcrossSupportedNewlines() throws {
    for newline in ["\n", "\r", "\r\n"] {
        let allowed = String(repeating: newline, count: TextFileReader.maximumLineCount - 1)
        try TextFileReader.validate(allowed)
        #expect(throws: TextFileReader.ReadError.tooManyLines) {
            try TextFileReader.validate(allowed + newline)
        }
    }
}

@Test func boundsLineWidthIncludingWideCharactersAndTabs() throws {
    for (character, width) in [("a", 1), ("界", 2), ("🌍", 2), ("\t", 4)] {
        let allowed = String(repeating: character, count: TextFileReader.maximumLineColumnCount / width)
        try TextFileReader.validate(allowed)
        #expect(throws: TextFileReader.ReadError.lineTooLong) {
            try TextFileReader.validate(allowed + character)
        }
    }
}
