import Foundation

/// Reads bounded, strictly decoded text without replacing invalid bytes.
public enum TextFileReader {
    public static let maximumByteCount = 5 * 1_024 * 1_024
    public static let maximumLineCount = 100_000
    public static let maximumLineColumnCount = 100_000

    public enum ReadError: LocalizedError, Equatable, Sendable {
        case tooLarge
        case unsupportedEncoding
        case binaryContent
        case notRegularFile
        case tooManyLines
        case lineTooLong

        public var errorDescription: String? {
            switch self {
            case .tooLarge:
                return "Text must be 5 MiB or smaller. Choose a smaller file or paste a smaller selection."
            case .unsupportedEncoding:
                return "The file is not valid UTF-8 or UTF-16 text. UTF-16 files need a byte-order mark."
            case .binaryContent:
                return "The file contains binary control characters. Choose a plain text file."
            case .notRegularFile:
                return "Choose a regular text file."
            case .tooManyLines:
                return "Text must contain at most 100,000 lines. Choose a smaller file or paste a smaller selection."
            case .lineTooLong:
                return "A line is longer than 100,000 display columns. Split long lines or choose a smaller selection."
            }
        }
    }

    public static func read(_ url: URL) throws -> String {
        try decode(readData(url))
    }

    static func readData(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw ReadError.notRegularFile }
        #if os(macOS)
        let scopedAccess = url.startAccessingSecurityScopedResource()
        defer { if scopedAccess { url.stopAccessingSecurityScopedResource() } }
        #endif

        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ReadError.notRegularFile }
        if let size = values.fileSize, size > maximumByteCount { throw ReadError.tooLarge }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        // Bound the read itself as well as the metadata check: a file can grow while open.
        while data.count <= maximumByteCount {
            try Task.checkCancellation()
            let remaining = maximumByteCount + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(65_536, remaining)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumByteCount else { throw ReadError.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> String {
        guard data.count <= maximumByteCount else { throw ReadError.tooLarge }
        let bytes = Array(data)
        let text: String?
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            throw ReadError.unsupportedEncoding
        } else if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            guard bytes.count.isMultiple(of: 2) else { throw ReadError.unsupportedEncoding }
            let littleEndian = bytes[0] == 0xFF
            let units: [UInt16] = stride(from: 2, to: bytes.count, by: 2).map { index in
                let first = UInt16(bytes[index])
                let second = UInt16(bytes[index + 1])
                return littleEndian ? first | (second << 8) : (first << 8) | second
            }
            // Foundation's UTF-16 decoder can repair malformed surrogates on some
            // platforms. Validate the code units before constructing the String.
            var index = 0
            while index < units.count {
                let unit = units[index]
                if (0xD800...0xDBFF).contains(unit) {
                    guard index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) else {
                        throw ReadError.unsupportedEncoding
                    }
                    index += 2
                } else {
                    guard !(0xDC00...0xDFFF).contains(unit) else { throw ReadError.unsupportedEncoding }
                    index += 1
                }
            }
            text = String(data: Data(bytes.dropFirst(2)), encoding: littleEndian ? .utf16LittleEndian : .utf16BigEndian)
        } else {
            let offset = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
            text = String(data: Data(bytes.dropFirst(offset)), encoding: .utf8)
        }

        guard let text else { throw ReadError.unsupportedEncoding }
        guard !text.unicodeScalars.contains(where: { scalar in
            scalar.value < 0x20 && ![0x09, 0x0A, 0x0C, 0x0D].contains(scalar.value)
        }) else { throw ReadError.binaryContent }
        try validate(text)
        return text
    }

    /// Applies the same resource limits to decoded files and text entered in the app.
    public static func validate(_ text: String) throws {
        // UTF-16 can expand beyond the byte budget when represented as UTF-8.
        guard text.utf8.count <= maximumByteCount else { throw ReadError.tooLarge }
        var lineCount = text.isEmpty ? 0 : 1
        var lineWidth = 0
        for character in text {
            if character == "\n" || character == "\r" || character == "\r\n" {
                lineCount += 1
                guard lineCount <= maximumLineCount else { throw ReadError.tooManyLines }
                lineWidth = 0
            } else {
                lineWidth += displayColumns(for: character)
                guard lineWidth <= maximumLineColumnCount else { throw ReadError.lineTooLong }
            }
        }
    }

    /// A conservative monospace width estimate, including emoji and CJK glyphs.
    public static func displayColumns(for character: Character) -> Int {
        if character == "\t" { return 4 }
        return character.unicodeScalars.contains(where: { !$0.isASCII }) ? 2 : 1
    }
}
