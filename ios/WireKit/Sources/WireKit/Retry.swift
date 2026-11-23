import Foundation

// Reading the watch again: after a firmware is sent (it installs and restarts for minutes) and when the link comes
// back. Pure, so the timing is tested without a watch.

/// Waits `every`, then tries; again until `attempt` says true or `limit` has gone by (counting the waits). true when
/// an attempt did. A cancelled wait ends it with false.
public func retry(every: Duration, for limit: Duration,
                  sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                  _ attempt: () async -> Bool) async -> Bool {
    var waited = Duration.zero
    while waited + every <= limit {
        do { try await sleep(every) } catch { return false }
        waited += every
        if await attempt() { return true }
    }
    return false
}

/// A read of the watch on a link that came back: only when the user has read it before (not `idle`), none runs, no
/// firmware restart is being waited for, and the last read began at least `gap` ago.
public func recheckDue(idle: Bool, busy: Bool, last: Date?, now: Date, gap: TimeInterval = 30) -> Bool {
    !idle && !busy && last.map { now.timeIntervalSince($0) >= gap } ?? true
}

/// How many installs, face and firmware sessions have the watch: the phone's listener stays off until the last one is
/// done, whatever else asks it to start meanwhile.
public struct WatchHolds: Sendable {
    private var count = 0
    public init() {}
    public var free: Bool { count == 0 }
    public mutating func take() { count += 1 }
    public mutating func release() { count = max(0, count - 1) }
}
