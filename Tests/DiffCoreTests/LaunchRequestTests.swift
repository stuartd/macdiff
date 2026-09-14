import Foundation
import Testing
@testable import DiffCore

private let launchDirectory = URL(fileURLWithPath: "/tmp/ClipDiff Session", isDirectory: true)

@Test func noLaunchArgumentsOpensEmptyComparison() throws {
    #expect(try LaunchRequest.parse([], currentDirectory: launchDirectory) == .empty)
}

@Test func launchPathsPreserveOrderSpacesAndUnicode() throws {
    let request = try LaunchRequest.parse(
        ["/tmp/previous text α.txt", "/tmp/current text 日本語.txt"],
        currentDirectory: launchDirectory
    )
    #expect(request == .compare(
        URL(fileURLWithPath: "/tmp/previous text α.txt"),
        URL(fileURLWithPath: "/tmp/current text 日本語.txt")
    ))
}

@Test func relativeLaunchPathsUseSuppliedWorkingDirectory() throws {
    let request = try LaunchRequest.parse(
        ["./previous.txt", "../current.txt"], currentDirectory: launchDirectory
    )
    #expect(request == .compare(
        URL(fileURLWithPath: "/tmp/ClipDiff Session/previous.txt"),
        URL(fileURLWithPath: "/tmp/current.txt")
    ))
}

@Test func launchPathsAreLiteralFilePaths() throws {
    let request = try LaunchRequest.parse(
        ["before%20.txt", "after#1?.txt"], currentDirectory: launchDirectory
    )
    #expect(request == .compare(
        URL(fileURLWithPath: "/tmp/ClipDiff Session/before%20.txt"),
        URL(fileURLWithPath: "/tmp/ClipDiff Session/after#1?.txt")
    ))
}

@Test(arguments: ["--help", "-h"])
func standaloneLaunchHelp(option: String) throws {
    #expect(try LaunchRequest.parse([option], currentDirectory: launchDirectory) == .help)
}

@Test func launchOptionSeparatorAllowsHyphenFilenames() throws {
    let request = try LaunchRequest.parse(
        ["--", "--help", "-changed.txt"], currentDirectory: launchDirectory
    )
    #expect(request == .compare(
        URL(fileURLWithPath: "/tmp/ClipDiff Session/--help"),
        URL(fileURLWithPath: "/tmp/ClipDiff Session/-changed.txt")
    ))
}

@Test(arguments: [["one.txt"], ["one.txt", "two.txt", "three.txt"], ["--", "one.txt"]])
func invalidLaunchArgumentCounts(arguments: [String]) {
    let fileCount = arguments.filter { $0 != "--" }.count
    #expect(throws: LaunchRequest.ParseError.invalidArgumentCount(fileCount)) {
        try LaunchRequest.parse(arguments, currentDirectory: launchDirectory)
    }
}

@Test func unknownLaunchOptionsReportUsage() {
    let error = LaunchRequest.ParseError.unknownOption("--merge")
    #expect(throws: error) {
        try LaunchRequest.parse(["--merge", "one.txt", "two.txt"], currentDirectory: launchDirectory)
    }
    #expect(error.localizedDescription.contains(LaunchRequest.usage))
}

@Test func launchHelpRejectsOtherArguments() {
    #expect(throws: LaunchRequest.ParseError.helpWithOtherArguments) {
        try LaunchRequest.parse(["--help", "one.txt"], currentDirectory: launchDirectory)
    }
}

@Test func emptyLaunchFilePathIsRejected() {
    #expect(throws: LaunchRequest.ParseError.emptyPath) {
        try LaunchRequest.parse(["", "two.txt"], currentDirectory: launchDirectory)
    }
}
