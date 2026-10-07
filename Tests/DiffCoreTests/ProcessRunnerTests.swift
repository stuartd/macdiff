import Foundation
import Testing
@testable import DiffCore

private func child(_ script: String) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    return process
}

@Test func processRunnerCollectsBothStreamsAndNonzeroStatus() async throws {
    let result = try await ProcessRunner.run(child("printf output; printf diagnostic >&2; exit 7"),
                                             outputLimit: 1024, limitMessage: "Too large")
    #expect(String(decoding: result.data, as: UTF8.self) == "output")
    #expect(result.error == "diagnostic" && result.status == 7)
}

@Test func processRunnerDrainsLargeStderrWithoutRetainingItAll() async throws {
    let result = try await ProcessRunner.run(child("head -c 200000 /dev/zero >&2; printf complete"),
                                             outputLimit: 1024, limitMessage: "Too large")
    #expect(String(decoding: result.data, as: UTF8.self) == "complete")
    #expect(result.error.utf8.count == 16_384 && result.status == 0)
}

@Test func cancellingSilentChildrenStopsAndReapsThem() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<8 {
        let ready = directory.appendingPathComponent("ready-\(index)")
        // exec keeps the PID stable; ignored SIGTERM exercises bounded escalation.
        let process = child("trap '' TERM; printf ready > '\(ready.path)'; exec /bin/sleep 60")
        let worker = Task {
            try await ProcessRunner.run(process, outputLimit: 1024, limitMessage: "Too large", timeout: 3)
        }
        defer { worker.cancel() }
        let launchDeadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: ready.path) {
            guard ContinuousClock.now < launchDeadline else { throw ProcessRunner.RunnerError("Child failed to start") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let start = ContinuousClock.now
        worker.cancel()
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(!process.isRunning)
    }
}

@Test func cancellingBeforeLaunchDoesNotStartAProcess() async {
    let process = child("exec /bin/sleep 60")
    let worker = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await ProcessRunner.run(process, outputLimit: 1024, limitMessage: "Too large")
    }
    await #expect(throws: CancellationError.self) { try await worker.value }
    #expect(!process.isRunning)
}

@Test func cancellingAfterCompletionLeavesTheResultIntact() async throws {
    let process = child("printf finished")
    let worker = Task { try await ProcessRunner.run(process, outputLimit: 1024, limitMessage: "Too large") }
    let result = try await worker.value
    worker.cancel()
    #expect(String(decoding: result.data, as: UTF8.self) == "finished" && result.status == 0)
    #expect(!process.isRunning)
}

@Test func processDeadlineStopsASilentChild() async {
    let process = child("trap '' TERM; exec /bin/sleep 60")
    let start = ContinuousClock.now
    await #expect(throws: ProcessRunner.RunnerError.self) {
        try await ProcessRunner.run(process, outputLimit: 1024, limitMessage: "Too large", timeout: 0.05)
    }
    #expect(start.duration(to: .now) < .seconds(2))
    #expect(!process.isRunning)
}

@Test func outputLimitStopsAConstantOutputChild() async {
    let process = child("exec /usr/bin/yes x")
    await #expect(throws: ProcessRunner.RunnerError.self) {
        try await ProcessRunner.run(process, outputLimit: 1024, limitMessage: "Too large", timeout: 2)
    }
    #expect(!process.isRunning)
}

@Test func processLaunchFailuresReturnWithoutWaitingForPipes() async {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/nonexistent-macdiff-test-program")
    await #expect(throws: (any Error).self) {
        try await ProcessRunner.run(process, outputLimit: 1024, limitMessage: "Too large")
    }
}
