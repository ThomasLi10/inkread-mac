import Foundation
import Darwin

enum ProcessEvent {
    case stdout(Data)
    case stderr(Data)
    case exited(Int32)
}

/// Only this class touches pipes. Its ordered stdout producer feeds one actor task.
final class ProcessTransport: @unchecked Sendable {
    let process: Process
    let events: AsyncStream<ProcessEvent>
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let continuation: AsyncStream<ProcessEvent>.Continuation
    private let outputClosed = DispatchSemaphore(value: 0)
    private let errorClosed = DispatchSemaphore(value: 0)

    init(executable: URL, arguments: [String], workspace: URL) throws {
        var producer: AsyncStream<ProcessEvent>.Continuation!
        events = AsyncStream { producer = $0 }
        continuation = producer
        process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        var environment = ProcessInfo.processInfo.environment
        // Do not print or copy credentials out of the official client's environment.
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let inheritedPath = environment["PATH"] ?? ""
        environment["PATH"] = (extraPaths + [inheritedPath]).joined(separator: ":")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let outputClosed = self.outputClosed
        let errorClosed = self.errorClosed
        let continuation = self.continuation
        process.terminationHandler = { process in
            DispatchQueue.global(qos: .utility).async {
                // Drain all final protocol bytes before reporting process exit.
                outputClosed.wait()
                errorClosed.wait()
                continuation.yield(.exited(process.terminationStatus))
                continuation.finish()
            }
        }
        try process.run()
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        errors.fileHandleForWriting.closeFile()
        read(output.fileHandleForReading, closed: outputClosed, event: ProcessEvent.stdout)
        read(errors.fileHandleForReading, closed: errorClosed, event: ProcessEvent.stderr)
    }

    private func read(_ handle: FileHandle, closed: DispatchSemaphore, event: @escaping (Data) -> ProcessEvent) {
        let continuation = self.continuation
        DispatchQueue.global(qos: .utility).async {
            defer { closed.signal() }
            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                // POSIX read returns as soon as *any* pipe bytes are available.
                // FileHandle.read(upToCount:) may wait to fill its requested count
                // on Darwin and would stall a small JSONL initialization reply.
                let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                if count > 0 { continuation.yield(event(Data(bytes.prefix(count)))) }
                else if count < 0 && errno == EINTR { continue }
                else { break }
            }
        }
    }

    func write(_ object: [String: Any]) throws {
        guard process.isRunning else { throw CodexBridgeError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        let process = self.process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    deinit {
        if process.isRunning { process.terminate() }
        continuation.finish()
    }
}
