import Foundation

/// Only an issued, uncancelled plan can grant a single write attempt.
final class DeviceWritePermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private var used = false
    var isUsable: Bool { lock.lock(); defer { lock.unlock() }; return valid && !used }
    func invalidate() { lock.lock(); defer { lock.unlock() }; valid = false }
    func consume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard valid && !used else { return false }
        used = true
        return true
    }
}
