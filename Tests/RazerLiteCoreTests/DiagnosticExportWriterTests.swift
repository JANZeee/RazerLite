import Foundation
import Testing
@testable import RazerLiteCore

struct DiagnosticExportWriterTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RazerLiteDiagnosticExportTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func writesExactDataAtTheDisplayedDestination() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = try DiagnosticExportDestination(directory: directory, fileName: "diagnostics.json")
        let data = Data("{\"schemaVersion\":2}".utf8)

        let written = try DiagnosticExportWriter().write(data, to: destination)

        #expect(written == destination.fileURL)
        #expect(try Data(contentsOf: written) == data)
    }

    @Test func existingFileIsRejectedWithoutChangingIt() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = try DiagnosticExportDestination(directory: directory, fileName: "diagnostics.json")
        let original = Data("original".utf8)
        try original.write(to: destination.fileURL)

        #expect(throws: DiagnosticExportError.destinationAlreadyExists) {
            try DiagnosticExportWriter().write(Data("replacement".utf8), to: destination)
        }
        #expect(try Data(contentsOf: destination.fileURL) == original)
    }

    @Test func rejectsTraversalMissingDirectoryAndNonJSONNames() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: DiagnosticExportError.invalidFileName) {
            try DiagnosticExportDestination(directory: directory, fileName: "../diagnostics.json")
        }
        #expect(throws: DiagnosticExportError.jsonExtensionRequired) {
            try DiagnosticExportDestination(directory: directory, fileName: "diagnostics.txt")
        }
        #expect(throws: DiagnosticExportError.absoluteDirectoryRequired) {
            try DiagnosticExportDestination(directoryPath: "Downloads", fileName: "diagnostics.json")
        }

        let destination = try DiagnosticExportDestination(directory: directory, fileName: "diagnostics.json")
        #expect(throws: DiagnosticExportError.directoryDoesNotExist) {
            try DiagnosticExportWriter().write(Data(), to: destination)
        }
    }
}
