import Foundation

/// Command-line arguments exclude the executable name. File loading and validation
/// belong to the document so failures can be presented in the app.
public enum LaunchRequest: Sendable, Equatable {
    case empty
    case compare(URL, URL)
    case help

    public static let usage = "Usage: MacDiff [original-file changed-file]"

    public enum ParseError: LocalizedError, Sendable, Equatable {
        case invalidArgumentCount(Int)
        case unknownOption(String)
        case helpWithOtherArguments
        case emptyPath

        public var errorDescription: String? {
            let explanation: String
            switch self {
            case let .invalidArgumentCount(count):
                explanation = "Expected either no files or two files; received \(count)."
            case let .unknownOption(option):
                explanation = "Unknown option: \(option). Use -- before filenames that begin with a hyphen."
            case .helpWithOtherArguments:
                explanation = "Use --help or -h on its own."
            case .emptyPath:
                explanation = "File paths must not be empty."
            }
            return "\(explanation)\n\(LaunchRequest.usage)"
        }
    }

    public static func parse(_ arguments: [String], currentDirectory: URL) throws -> LaunchRequest {
        var paths: [String] = []
        var acceptsOptions = true
        for argument in arguments {
            if acceptsOptions, argument == "--" {
                acceptsOptions = false
            } else if acceptsOptions, argument == "--help" || argument == "-h" {
                guard arguments.count == 1 else { throw ParseError.helpWithOtherArguments }
                return .help
            } else if acceptsOptions, argument.hasPrefix("-") {
                throw ParseError.unknownOption(argument)
            } else {
                guard !argument.isEmpty else { throw ParseError.emptyPath }
                paths.append(argument)
            }
        }

        if paths.isEmpty { return .empty }
        guard paths.count == 2 else { throw ParseError.invalidArgumentCount(paths.count) }

        let directory = URL(fileURLWithPath: currentDirectory.path, isDirectory: true)
        func fileURL(_ path: String) -> URL {
            URL(fileURLWithPath: path, isDirectory: false, relativeTo: directory).absoluteURL.standardizedFileURL
        }
        return .compare(fileURL(paths[0]), fileURL(paths[1]))
    }
}
