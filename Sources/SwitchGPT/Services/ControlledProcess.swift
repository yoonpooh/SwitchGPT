import Foundation

/// Cancellation is shared with synchronous CLI probes running off the main actor.
final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

enum ControlledProcess {
    /// Poll nonblocking pipes so neither an uncooperative CLI nor inherited stdout defeats the deadline.
    static func capture(_ process: Process, input: Data, timeout: TimeInterval,
                        cancellation: ProcessCancellation? = nil) throws -> Data {
        let stdin = Pipe(), stdout = Pipe()
        let reader = stdout.fileHandleForReading, writer = stdin.fileHandleForWriting
        defer {
            try? reader.close(); try? writer.close()
            try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
        }
        guard fcntl(reader.fileDescriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(writer.fileDescriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw ClaudeFailure(status: 502, message: "Could not prepare Claude Code control pipes")
        }
        if cancellation?.isCancelled == true { throw CancellationError() }
        let owned = try OwnedProcess(process, input: stdin.fileHandleForReading.fileDescriptor,
                                     output: stdout.fileHandleForWriting.fileDescriptor)
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, timeout)))
        var output = Data(), sent = 0
        var inputClosed = false, eof = false
        var buffer = [UInt8](repeating: 0, count: 65_536)
        defer { owned.stop() }
        while true {
            if cancellation?.isCancelled == true { throw CancellationError() }
            guard ContinuousClock.now < deadline else {
                throw ClaudeFailure(status: 504, message: "Claude Code control request timed out")
            }
            if !inputClosed {
                let written = input.withUnsafeBytes { bytes in
                    write(writer.fileDescriptor, bytes.baseAddress?.advanced(by: sent), min(input.count - sent, 65_536))
                }
                if written > 0 { sent += written }
                else if written < 0 && errno != EAGAIN && errno != EINTR { sent = input.count }
                if sent == input.count { try? writer.close(); inputClosed = true }
            }
            // Bound each drain so continuous output cannot postpone the deadline check.
            for _ in 0..<16 where !eof {
                let count = buffer.withUnsafeMutableBytes { read(reader.fileDescriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    output.append(contentsOf: buffer.prefix(count))
                } else if count == 0 { eof = true }
                else if errno == EAGAIN || errno == EINTR { break }
                else { throw ClaudeFailure(status: 502, message: "Could not read Claude Code control output") }
            }
            if eof && !owned.isRunning {
                _ = try owned.terminationStatus()
                return output
            }
            usleep(10_000)
        }
    }
}
