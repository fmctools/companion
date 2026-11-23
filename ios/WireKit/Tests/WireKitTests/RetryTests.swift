import Foundation
import Testing
@testable import WireKit

/// Sleeps that only count.
final class FakeClock: @unchecked Sendable {
    var now = Duration.zero
    func sleep(_ d: Duration) async throws { now += d }
}

@Test func retryWaitsThenTriesUntilItAnswers() async {
    let clock = FakeClock()
    var tries: [Duration] = []
    let ok = await retry(every: .seconds(20), for: .seconds(600), sleep: clock.sleep) {
        tries.append(clock.now)
        return tries.count == 3
    }
    #expect(ok)
    #expect(tries == [.seconds(20), .seconds(40), .seconds(60)], "the first try after one wait: the watch is installing")
}

@Test func retryGivesUpAfterTheLimit() async {
    let clock = FakeClock()
    var n = 0
    let ok = await retry(every: .seconds(20), for: .seconds(600), sleep: clock.sleep) { n += 1; return false }
    #expect(!ok && n == 30 && clock.now == .seconds(600))
}

@Test func retryStopsWhenCancelled() async {
    var n = 0
    let ok = await retry(every: .seconds(20), for: .seconds(600), sleep: { _ in throw CancellationError() }) { n += 1; return true }
    #expect(!ok && n == 0)
}

@Test func recheckDebounces() {
    let t = Date(timeIntervalSince1970: 1000)
    #expect(recheckDue(idle: false, busy: false, last: nil, now: t))
    #expect(!recheckDue(idle: true, busy: false, last: nil, now: t), "never read: the user connects first")
    #expect(!recheckDue(idle: false, busy: true, last: nil, now: t), "a read, install or restart wait runs")
    #expect(!recheckDue(idle: false, busy: false, last: t - 10, now: t))
    #expect(recheckDue(idle: false, busy: false, last: t - 30, now: t))
}

@Test func watchHoldsOverlap() {
    var h = WatchHolds()
    #expect(h.free, "nothing has the watch: a check may start the listener")
    h.take() // the firmware
    h.take() // a read of the faces meanwhile
    h.release()
    #expect(!h.free, "the second one ending doesn't start the listener under the firmware")
    h.release()
    #expect(h.free)
    h.release()
    h.take()
    #expect(!h.free, "a release too many doesn't eat the next hold")
}
