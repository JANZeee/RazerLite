import Darwin
import Foundation

protocol BluetoothSnapshotLoading: Sendable { func load() async throws -> Data }

enum SnapshotProcessError: LocalizedError, Equatable {
    case timedOut, outputLimit, failed
    var errorDescription: String? {
        switch self {
        case .timedOut: "系统蓝牙快照读取超时；已结束本次诊断进程。"
        case .outputLimit: "系统蓝牙快照超过大小限制；已停止读取。"
        case .failed: "系统蓝牙诊断未正常完成，请稍后重试。"
        }
    }
}

/// One bounded process at a time, on demand. Raw output is used in memory and never logged or saved.
struct SystemProfilerSnapshotLoader: BluetoothSnapshotLoading {
    private static let queue = DispatchQueue(label: "local.RazerLite.system-battery", qos: .utility)
    var executable = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    var arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic", "-timeout", "6"]
    var timeout: TimeInterval = 8
    var outputLimit = 4 * 1024 * 1024

    func load() async throws -> Data {
        let capture = SnapshotProcessCapture()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    do { continuation.resume(returning: try capture.run(self)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { capture.stop(CancellationError()) }
    }
}

/// The lock protects only child-process lifetime and the terminal error, never pipe reads or waits.
private final class SnapshotProcessCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var terminalError: (any Error)?
    private var finished = false

    func stop(_ error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, terminalError == nil else { return }
        terminalError = error
        if let process, process.isRunning {
            // Only the child created below, while its lifetime is protected by this lock.
            kill(process.processIdentifier, SIGKILL)
        }
    }

    func run(_ options: SystemProfilerSnapshotLoader) throws -> Data {
        let child = Process()
        let pipe = Pipe()
        child.executableURL = options.executable
        child.arguments = options.arguments
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        lock.lock()
        if let terminalError { lock.unlock(); throw terminalError }
        process = child
        do { try child.run() }
        catch { finished = true; process = nil; lock.unlock(); throw SnapshotProcessError.failed }
        lock.unlock()
        let deadline = DispatchWorkItem { [self] in stop(SnapshotProcessError.timedOut) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + options.timeout, execute: deadline)
        defer {
            deadline.cancel()
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        var output = Data()
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                guard output.count + chunk.count <= options.outputLimit else { stop(SnapshotProcessError.outputLimit); break }
                output.append(chunk)
            }
        } catch { stop(SnapshotProcessError.failed) }
        child.waitUntilExit()
        lock.lock()
        finished = true
        process = nil
        let error = terminalError
        lock.unlock()
        if let error { throw error }
        guard child.terminationReason == .exit, child.terminationStatus == 0 else { throw SnapshotProcessError.failed }
        return output
    }
}
