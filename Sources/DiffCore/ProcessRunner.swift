import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// All lifecycle and pipe state is confined to one serial queue. Nonblocking
/// reads keep cancellation responsive even when a child produces no output.
enum ProcessRunner {
    struct Result: Sendable {
        let data: Data
        let status: Int32
        let error: String
    }

    struct RunnerError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func run(_ process: Process, outputLimit: Int, limitMessage: String,
                    timeout: TimeInterval = 30) async throws -> Result {
        let state = State(process: process, outputLimit: outputLimit,
                          limitMessage: limitMessage, timeout: timeout)
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { state.start($0) }
        } onCancel: {
            state.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    private final class State: @unchecked Sendable {
        private let queue = DispatchQueue(label: "MacDiff.ProcessRunner")
        private let process: Process
        private let stdout = Pipe()
        private let stderr = Pipe()
        private let outputLimit: Int
        private let limitMessage: String
        private let timeout: TimeInterval
        private var continuation: CheckedContinuation<Result, any Error>?
        private var outputSource: DispatchSourceRead?
        private var errorSource: DispatchSourceRead?
        private var deadline: DispatchSourceTimer?
        private var output = Data()
        private var errors = Data()
        private var outputEnded = false
        private var errorsEnded = false
        private var exited = false
        private var cancelled = false
        private var failure: (any Error)?

        init(process: Process, outputLimit: Int, limitMessage: String, timeout: TimeInterval) {
            self.process = process
            self.outputLimit = outputLimit
            self.limitMessage = limitMessage
            self.timeout = timeout
        }

        func start(_ continuation: CheckedContinuation<Result, any Error>) {
            queue.async { self.launch(continuation) }
        }

        func cancel() {
            queue.async {
                self.cancelled = true
                if self.continuation != nil { self.stop(CancellationError()) }
            }
        }

        private func launch(_ continuation: CheckedContinuation<Result, any Error>) {
            self.continuation = continuation
            guard !cancelled else { finish(.failure(CancellationError())); return }
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.exited = true
                    self.completeIfPossible()
                }
            }
            do {
                outputSource = try reader(stdout.fileHandleForReading, isError: false)
                errorSource = try reader(stderr.fileHandleForReading, isError: true)
                try process.run()
                // Only the child owns the write ends now, so EOF follows exit.
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler { [weak self] in
                    self?.stop(RunnerError("Git took too long to respond. Try refreshing the repository."))
                }
                deadline = timer
                timer.resume()
            } catch {
                finish(.failure(error))
            }
        }

        private func reader(_ handle: FileHandle, isError: Bool) throws -> DispatchSourceRead {
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.drain(descriptor, isError: isError) }
            source.setCancelHandler { try? handle.close() }
            source.resume()
            return source
        }

        private func drain(_ descriptor: Int32, isError: Bool) {
            guard continuation != nil else { return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            // Yield to cancellation and the other stream even for constant output.
            for _ in 0..<16 {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress!, $0.count) }
                if count > 0 {
                    if isError {
                        // Drain all stderr, retaining only a bounded diagnostic.
                        errors.append(contentsOf: buffer.prefix(min(count, max(0, 16_384 - errors.count))))
                    } else if count > outputLimit - output.count {
                        stop(RunnerError(limitMessage))
                        return
                    } else {
                        output.append(contentsOf: buffer.prefix(count))
                    }
                } else if count == 0 {
                    if isError { errorsEnded = true; errorSource?.cancel() }
                    else { outputEnded = true; outputSource?.cancel() }
                    completeIfPossible()
                    return
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                } else {
                    stop(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                    return
                }
            }
        }

        private func stop(_ error: any Error) {
            guard continuation != nil, failure == nil else { return }
            failure = error
            if process.isRunning {
                process.terminate()
                // A child may ignore SIGTERM. Escalate without blocking a worker.
                queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                    guard let self, self.continuation != nil, self.process.isRunning else { return }
                    _ = kill(self.process.processIdentifier, SIGKILL)
                }
            } else {
                completeIfPossible()
            }
        }

        private func completeIfPossible() {
            guard continuation != nil else { return }
            if let failure, !process.isRunning {
                finish(.failure(failure))
            } else if exited && outputEnded && errorsEnded {
                finish(.success(Result(data: output, status: process.terminationStatus,
                                       error: String(decoding: errors, as: UTF8.self)
                                           .trimmingCharacters(in: .whitespacesAndNewlines))))
            }
        }

        private func finish(_ result: Swift.Result<Result, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            deadline?.cancel()
            outputSource?.cancel()
            errorSource?.cancel()
            process.terminationHandler = nil
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            if outputSource == nil { try? stdout.fileHandleForReading.close() }
            if errorSource == nil { try? stderr.fileHandleForReading.close() }
            continuation.resume(with: result)
        }
    }
}
