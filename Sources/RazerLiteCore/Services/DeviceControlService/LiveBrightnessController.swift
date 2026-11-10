import Foundation

/// Coalesces explicit UI edits only. There is no idle timer or saved/replayed target.
/// The owner supplies device/session validation and keeps its physical I/O reservation
/// until `apply` returns, including after cancellation.
@MainActor
final class LiveBrightnessController {
    typealias Apply = @MainActor (Int, LiveBrightnessPermit) async -> Bool

    private let apply: Apply
    private let onStateChange: @MainActor () -> Void
    private let sleep: @MainActor (Duration) async throws -> Void
    private let now: @MainActor () -> ContinuousClock.Instant
    private let minimumInterval: Duration
    private let initialDelay: Duration
    private var worker: Task<Void, Never>?
    private var pending: Int?
    private var active: Int?
    private var requested: Int?
    private var activePermit: LiveBrightnessPermit?
    private var lastStartedAt: ContinuousClock.Instant?
    private var isCancelled = false

    var hasWork: Bool { worker != nil }
    var target: Int? { requested }

    init(minimumInterval: Duration = .milliseconds(250), initialDelay: Duration = .milliseconds(150),
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
         onStateChange: @escaping @MainActor () -> Void = {}, apply: @escaping Apply) {
        self.minimumInterval = minimumInterval
        self.initialDelay = initialDelay
        self.sleep = sleep
        self.now = now
        self.onStateChange = onStateChange
        self.apply = apply
    }

    /// Returns false for invalid input or while cancelled work is still draining.
    @discardableResult func submit(percent: Int) -> Bool {
        guard (0...100).contains(percent), !(isCancelled && worker != nil) else { return false }
        requested = percent
        // Returning to the in-flight target supersedes an older pending edit too.
        pending = percent == active ? nil : percent
        if worker == nil {
            isCancelled = false
            worker = Task { [weak self] in await self?.run() }
        }
        onStateChange()
        return true
    }

    func cancel() {
        isCancelled = true
        pending = nil
        requested = nil
        activePermit?.invalidate()
        worker?.cancel()
        onStateChange()
    }

    private func run() async {
        defer {
            pending = nil
            active = nil
            requested = nil
            activePermit?.invalidate()
            activePermit = nil
            worker = nil
            onStateChange()
        }
        do {
            guard !Task.isCancelled, !isCancelled else { return }
            // Small leading coalescing window, then throttle rather than debounce:
            // continuous dragging still applies periodically and preserves the last edit.
            try await sleep(initialDelay)
            while !Task.isCancelled && !isCancelled, pending != nil {
                if let lastStartedAt {
                    let remaining = minimumInterval - lastStartedAt.duration(to: now())
                    if remaining > .zero { try await sleep(remaining) }
                }
                guard !Task.isCancelled, !isCancelled, let value = pending else { return }
                pending = nil
                active = value
                let permit = LiveBrightnessPermit()
                activePermit = permit
                lastStartedAt = now()
                onStateChange()
                let succeeded = await apply(value, permit)
                permit.invalidate()
                activePermit = nil
                active = nil
                guard !Task.isCancelled, !isCancelled, succeeded else { return }
                onStateChange()
            }
        } catch {
            // Cancellation of the scheduled delay cannot submit a trailing command.
        }
    }
}
