import Foundation
import IOKit
import Testing
@testable import RazerLiteCore

struct ReadFailureKindTests {
    @Test func titlesAndRawValuesAreStable() throws {
        #expect(ReadFailureKind.notPublished.rawValue == "notPublished")
        #expect(ReadFailureKind.protocolMismatch.title == "响应不匹配")
        #expect(ReadFailureKind.permissionDenied.title == "权限不足")
        #expect(try JSONDecoder().decode(ReadFailureKind.self, from: Data("\"busy\"".utf8)) == .busy)
    }

    @Test func oldIssueAndSystemBatteryJSONDecodeWithoutFailureKinds() throws {
        let issue = try JSONDecoder().decode(MouseReadIssue.self, from: Data("""
        {"field":"battery","message":"旧诊断消息"}
        """.utf8))
        #expect(issue.field == "battery")
        #expect(issue.message == "旧诊断消息")
        #expect(issue.kind == nil)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let reading = try decoder.decode(SystemBatteryReading.self, from: Data("""
        {"deviceID":"hid-1","interfaceIDs":[1],"acquiredAt":"2026-10-19T00:00:00Z","percent":null,"source":null,"issue":"旧诊断消息"}
        """.utf8))
        #expect(reading.percent == nil)
        #expect(reading.source == nil)
        #expect(reading.issue == "旧诊断消息")
        #expect(reading.failureKind == nil)
    }

    @Test func existingInitializersKeepNilFailureKinds() {
        let issue = MouseReadIssue(field: "dpi", message: "旧调用")
        let reading = SystemBatteryReading(deviceID: "hid-1", interfaceIDs: [1], acquiredAt: Date(),
                                           percent: nil, source: nil, issue: "旧调用")
        #expect(issue.kind == nil)
        #expect(reading.failureKind == nil)
    }

    @Test func knownReadErrorsUseSpecificCategories() {
        #expect(MouseReadService.failureKind(for: MouseQueryError.unavailableInterface) == .unavailable)
        #expect(MouseReadService.failureKind(for: MouseQueryError.unsupportedDevice) == .unsupported)
        #expect(MouseReadService.failureKind(for: MouseQueryError.deviceChanged) == .disconnected)
        #expect(MouseReadService.failureKind(for: MouseQueryError.busyTimeout) == .busy)
        #expect(MouseReadService.failureKind(for: MouseQueryError.mismatchedResponse(transaction: 1, commandClass: 4, commandID: 0x86)) == .protocolMismatch)
        #expect(MouseReadService.failureKind(for: MouseQueryError.malformed("fixture")) == .invalidData)
        #expect(MouseReadService.failureKind(for: MouseQueryError.rejected(3)) == .deviceRejected)
        #expect(MouseReadService.failureKind(for: MouseQueryError.rejected(4)) == .timeout)
        #expect(MouseReadService.failureKind(for: MouseQueryError.rejected(5)) == .unsupported)

        #expect(SystemBatteryService.failureKind(for: SystemBatteryError.missingAddress) == .notPublished)
        #expect(SystemBatteryService.failureKind(for: SystemBatteryError.identityMismatch) == .protocolMismatch)
        #expect(SystemBatteryService.failureKind(for: SystemBatteryError.ambiguous) == .invalidData)
        #expect(SystemBatteryService.failureKind(for: SnapshotProcessError.timedOut) == .timeout)
        #expect(SystemBatteryService.failureKind(for: SnapshotProcessError.outputLimit) == .invalidData)
        #expect(SystemBatteryService.failureKind(for: CancellationError()) == .cancelled)
    }

    @Test func ioReturnCodesKeepPermissionTimeoutAndDisconnectDistinct() {
        #expect(ReadFailureClassifier.classify(MouseQueryError.io(operation: "fixture", code: kIOReturnNotPermitted)) == .permissionDenied)
        #expect(ReadFailureClassifier.classify(MouseQueryError.io(operation: "fixture", code: kIOReturnNotPrivileged)) == .permissionDenied)
        #expect(ReadFailureClassifier.classify(MouseQueryError.io(operation: "fixture", code: kIOReturnTimeout)) == .timeout)
        #expect(ReadFailureClassifier.classify(MouseQueryError.io(operation: "fixture", code: kIOReturnNoDevice)) == .disconnected)
        #expect(ReadFailureClassifier.classify(MouseQueryError.io(operation: "fixture", code: kIOReturnNotAttached)) == .disconnected)
        #expect(ReadFailureClassifier.classify(MouseQueryError.io(operation: "fixture", code: -1)) == .io)
    }
}
