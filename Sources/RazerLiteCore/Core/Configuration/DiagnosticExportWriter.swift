import Darwin
import Foundation

/// A user-chosen JSON file destination. The name is intentionally kept separate
/// from the directory so an export cannot escape the displayed folder.
public struct DiagnosticExportDestination: Equatable, Sendable {
    public let directory: URL
    public let fileName: String

    /// Use this initializer for text entered in the app. It refuses a relative
    /// path before Foundation could resolve it against the process working
    /// directory and produce an unexpected export location.
    public init(directoryPath: String, fileName: String) throws {
        let expandedPath = (directoryPath as NSString).expandingTildeInPath
        guard expandedPath.hasPrefix("/") else { throw DiagnosticExportError.absoluteDirectoryRequired }
        try self.init(directory: URL(fileURLWithPath: expandedPath, isDirectory: true), fileName: fileName)
    }

    public init(directory: URL, fileName: String) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/") else { throw DiagnosticExportError.invalidDirectory }

        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let containsSeparator = trimmed.contains("/") || trimmed.contains("\\")
        let containsNUL = trimmed.unicodeScalars.contains { $0.value == 0 }
        guard !trimmed.isEmpty, trimmed == fileName, trimmed != ".", trimmed != "..", !containsSeparator, !containsNUL else {
            throw DiagnosticExportError.invalidFileName
        }
        guard (trimmed as NSString).pathExtension.lowercased() == "json" else {
            throw DiagnosticExportError.jsonExtensionRequired
        }

        self.directory = directory.standardizedFileURL
        self.fileName = trimmed
    }

    public var fileURL: URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }
}

public enum DiagnosticExportError: Error, LocalizedError, Equatable, Sendable {
    case invalidDirectory
    case absoluteDirectoryRequired
    case invalidFileName
    case jsonExtensionRequired
    case directoryDoesNotExist
    case destinationIsNotDirectory
    case destinationAlreadyExists
    case createFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory:
            "导出位置必须是本机文件夹。"
        case .absoluteDirectoryRequired:
            "请输入以 / 开头的完整文件夹路径，或使用“选择文件夹…”。"
        case .invalidFileName:
            "文件名不能为空，不能包含路径分隔符或首尾空格。"
        case .jsonExtensionRequired:
            "文件名必须以 .json 结尾。"
        case .directoryDoesNotExist:
            "所选文件夹不存在。请选择已有文件夹或检查输入的路径。"
        case .destinationIsNotDirectory:
            "所选导出位置不是文件夹。"
        case .destinationAlreadyExists:
            "已有同名文件。为避免覆盖，请修改文件名后再保存。"
        case let .createFailed(message):
            "无法创建 JSON 文件：\(message)"
        case let .writeFailed(message):
            "写入 JSON 文件失败：\(message)"
        }
    }
}

/// Writes a diagnostic export exactly once at a user-visible path.
///
/// `O_EXCL` is deliberately used instead of a prior existence check plus a
/// normal write. That final filesystem operation rejects a racing same-name
/// file and therefore never silently replaces an existing export.
public struct DiagnosticExportWriter {
    public init() {}

    @discardableResult
    public func write(_ data: Data, to destination: DiagnosticExportDestination) throws -> URL {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: destination.directory.path, isDirectory: &isDirectory) else {
            throw DiagnosticExportError.directoryDoesNotExist
        }
        guard isDirectory.boolValue else { throw DiagnosticExportError.destinationIsNotDirectory }

        let permissions: mode_t = S_IRUSR | S_IWUSR
        let descriptor = destination.fileURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, permissions)
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == EEXIST { throw DiagnosticExportError.destinationAlreadyExists }
            throw DiagnosticExportError.createFailed(Self.posixMessage(for: code))
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            return destination.fileURL
        } catch {
            try? handle.close()
            // This process created the path exclusively. Removing a failed,
            // partial export is safe and avoids presenting a corrupt JSON file.
            try? fileManager.removeItem(at: destination.fileURL)
            throw DiagnosticExportError.writeFailed(error.localizedDescription)
        }
    }

    private static func posixMessage(for code: Int32) -> String {
        String(cString: strerror(code))
    }
}
