import Foundation
import Darwin

struct ProcessOutput: Sendable {
    let stdout: Data
    let stderr: Data
}

private final class BoundedOutput: @unchecked Sendable {
    private let limit: Int
    private var data = Data()
    private let lock = NSLock()

    init(limit: Int) { self.limit = limit }

    func read(_ handle: FileHandle) {
        while let chunk = try? handle.read(upToCount: 16 * 1024), !chunk.isEmpty {
            lock.lock()
            data.append(chunk)
            if data.count > limit { data.removeFirst(data.count - limit) }
            lock.unlock()
        }
        try? handle.close()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func run(executable: URL, arguments: [String], directory: URL? = nil, outputLimit: Int = 64 * 1024) async throws -> ProcessOutput {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try self.execute(executable: executable, arguments: arguments, directory: directory, outputLimit: outputLimit) }
                    self.lock.lock()
                    self.finished = true
                    self.lock.unlock()
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        guard let running, running.isRunning else { return }
        running.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if running.isRunning { Darwin.kill(running.processIdentifier, SIGKILL) }
        }
    }

    private func execute(executable: URL, arguments: [String], directory: URL?, outputLimit: Int) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let output = BoundedOutput(limit: outputLimit)
        let errors = BoundedOutput(limit: 64 * 1024)
        let readers = DispatchGroup()
        // Drain both pipes concurrently so a full stderr pipe cannot deadlock FFmpeg.
        for (pipe, buffer) in [(stdout, output), (stderr, errors)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                buffer.read(pipe.fileHandleForReading)
                readers.leave()
            }
        }
        lock.lock()
        if cancelled {
            lock.unlock()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            readers.wait()
            throw CancellationError()
        }
        self.process = process
        do {
            try process.run()
            lock.unlock()
        } catch {
            self.process = nil
            lock.unlock()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            readers.wait()
            throw error
        }
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        process.waitUntilExit()
        readers.wait()
        lock.lock()
        let wasCancelled = cancelled
        self.process = nil
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if message.localizedCaseInsensitiveContains("No space left on device") { throw MediaPipelineError.insufficientSpace }
            throw MediaPipelineError.processFailed(executable.lastPathComponent, message.isEmpty ? String(format: NSLocalizedString("The process exited with code %d.", comment: ""), process.terminationStatus) : message)
        }
        return ProcessOutput(stdout: output.value, stderr: errors.value)
    }
}
