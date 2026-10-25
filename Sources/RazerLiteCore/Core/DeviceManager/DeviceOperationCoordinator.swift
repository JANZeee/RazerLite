import Foundation

enum DeviceOperation: Sendable {
    case mouse, battery, polling, charging, keyboardBattery, keyboardCharging, systemBattery, dpiPrepare, dpiApply

    var fields: Set<String> {
        switch self {
        case .mouse: ["battery", "dpi", "stages"]
        case .polling: ["polling"]
        case .charging, .keyboardCharging: ["charging"]
        case .battery, .keyboardBattery, .systemBattery: ["battery"]
        case .dpiPrepare, .dpiApply: []
        }
    }
}

struct DeviceOperationTicket: Sendable {
    let id = UUID()
    let deviceID: String
    let generation: UUID
    let operation: DeviceOperation
}

/// Owns logical session validity separately from an operation's physical lifetime.
/// Invalidating a session never releases its reservation: synchronous IOKit work may still be running.
@MainActor
final class DeviceOperationCoordinator {
    private enum Route {
        case hid(HIDInterface)
        case system(DeviceInfo)

        func matches(_ other: Route) -> Bool {
            switch (self, other) {
            case let (.hid(lhs), .hid(rhs)): lhs.matchesSession(rhs)
            case let (.system(lhs), .system(rhs)): lhs == rhs
            default: false
            }
        }
    }
    private struct Session {
        let generation = UUID()
        let route: Route
    }
    private struct Reservation {
        let ticket: DeviceOperationTicket
        var cancelled = false
    }
    private var sessions: [String: Session] = [:]
    private var reservations: [String: Reservation] = [:]
    var hasReservations: Bool { !reservations.isEmpty }
    func generation(for deviceID: String) -> UUID? { sessions[deviceID]?.generation }

    /// Returns IDs whose session changed, so callers can discard cached values too.
    @discardableResult
    func reconcile(_ devices: [DeviceInfo]) -> Set<String> {
        var next: [String: Session] = [:]
        for device in devices {
            let route: Route
            if let interface = ViperV4Adapter.controlInterface(in: device)
                ?? BlackWidowLowProfileAdapter.controlInterface(in: device) {
                route = .hid(interface)
            } else if SystemBatteryService.canRead(device) {
                route = .system(device)
            } else { continue }
            if let old = sessions[device.id], old.route.matches(route) { next[device.id] = old }
            else { next[device.id] = Session(route: route) }
        }
        let changed = Set(sessions.keys).union(next.keys).filter { sessions[$0]?.generation != next[$0]?.generation }
        sessions = next
        return Set(changed)
    }

    func invalidateSessions() { sessions.removeAll() }

    func begin(_ operation: DeviceOperation, for deviceID: String) -> DeviceOperationTicket? {
        guard reservations[deviceID] == nil, let session = sessions[deviceID] else { return nil }
        let ticket = DeviceOperationTicket(deviceID: deviceID, generation: session.generation, operation: operation)
        reservations[deviceID] = Reservation(ticket: ticket)
        return ticket
    }

    func isCurrent(_ ticket: DeviceOperationTicket) -> Bool {
        guard let reservation = reservations[ticket.deviceID] else { return false }
        return reservation.ticket.id == ticket.id && !reservation.cancelled
            && sessions[ticket.deviceID]?.generation == ticket.generation
    }

    func cancel(_ ticket: DeviceOperationTicket) {
        guard reservations[ticket.deviceID]?.ticket.id == ticket.id else { return }
        reservations[ticket.deviceID]?.cancelled = true
    }

    func cancelActive(for deviceID: String) {
        guard let ticket = reservations[deviceID]?.ticket else { return }
        cancel(ticket)
    }

    /// Call only once the service has actually returned, including discarded responses.
    func finish(_ ticket: DeviceOperationTicket) {
        guard reservations[ticket.deviceID]?.ticket.id == ticket.id else { return }
        reservations.removeValue(forKey: ticket.deviceID)
    }

    func isBusy(_ deviceID: String) -> Bool { reservations[deviceID] != nil }
    func isDraining(_ deviceID: String) -> Bool {
        reservations[deviceID].map { !isCurrent($0.ticket) } ?? false
    }
    func activeOperation(for deviceID: String) -> DeviceOperation? {
        guard let reservation = reservations[deviceID], isCurrent(reservation.ticket) else { return nil }
        return reservation.ticket.operation
    }
}
