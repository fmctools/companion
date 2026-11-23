import Foundation

// Weather's widget card, kept fresh by the phone (stub 10, docs/miniapp-rpc.md "Weather's card"): now and the next three
// hours as a v2 `columns` record, the same bytes the Weather app writes from the same answer. It is built from the
// `weather` RPC's own records, so both sides round, clamp and count the hours alike.

/// The store's package that gets the card.
public let weatherPackage = "weather"

/// A forecast's hours from the one that contains `now`, counted on the phone's clock: a cached copy may start hours
/// back. `hour` is the first one's own, so one that only starts after this hour doesn't pass for it. nil when every
/// hour of it has passed.
public func currentHours(_ forecast: [(start: Date, hour: WeatherHour)], now: Date, calendar: Calendar) -> WeatherHours? {
    let thisHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
    let left = forecast.filter { $0.start >= thisHour }
    guard let first = left.first else { return nil }
    return WeatherHours(hour: calendar.component(.hour, from: first.start), hours: left.map(\.hour))
}

/// The icon's index in Weather's package: its `model::Icon` order (clear, partly, cloud, fog, drizzle, rain, snow,
/// storm), then clear (8) and partly (9) at night. A contract with that package: append only.
func weatherIcon(_ code: Int, night: Bool) -> Int {
    switch code {
    case 0: night ? 8 : 0
    case 1, 2: night ? 9 : 1
    case 45, 48: 3
    case 51...57: 4
    case 61...67, 80...82: 5
    case 71...77, 85, 86: 6
    case 95...99: 7
    default: 2
    }
}

/// Now, then the next three hours after the one that contains now (fewer when fewer are known), from the records
/// `weather` answers at `hour` (0–23) of the phone's clock. Night is only what an hourly entry's bit says; for Now
/// that of the entry that contains now, day without one. nil without the current record: then the phone writes
/// nothing.
public func weatherCard(_ records: [Data], hour: Int) -> Data? {
    let records = records.map { [UInt8]($0) }
    guard let now = records.first(where: { $0.first == 0 && $0.count >= 4 }) else { return nil }
    let tenths = Int(Int16(bitPattern: UInt16(now[1]) | UInt16(now[2]) << 8))
    let degrees = tenths >= 0 ? (tenths + 5) / 10 : -((5 - tenths) / 10) // halves away from zero, never "-0"
    var next: [WidgetColumn] = [], nightNow = false
    if let h = records.first(where: { $0.first == 2 && $0.count >= 5 }) {
        // how far entry 0 is ahead of the hour that contains now: 0 unless the forecast only starts later
        let ahead = (Int(h[1]) - hour + 24) % 24, count = (h.count - 2) / 3
        nightNow = ahead == 0 && h[4] & 0x80 != 0
        for later in 1...3 where (0..<count).contains(later - ahead) {
            let i = later - ahead, at = 2 + 3 * i
            next.append(WidgetColumn(caption: String(format: "%02d:00", (Int(h[1]) + i) % 24),
                                     icon: weatherIcon(Int(h[at + 1]), night: h[at + 2] & 0x80 != 0),
                                     value: "\(Int8(bitPattern: h[at]))\u{B0}"))
        }
    }
    let first = WidgetColumn(caption: "Now", icon: weatherIcon(Int(now[3]), night: nightNow), value: "\(degrees)\u{B0}")
    return columnsRecord([first] + next)
}

/// Weather's slot when the phone may push its card: stub 10 or later, the app on the watch by its package name and
/// holding the weather grant. Never a v1 card to an older stub: it would replace the app's own.
public func weatherCardSlot(stub: UInt32, apps: [Int: String], granted: Bool) -> Int? {
    guard granted, canPushColumns(stub: stub) else { return nil }
    return apps.filter { (0..<appSlots(stub: stub)).contains($0.key) && $0.value == weatherPackage }.keys.min()
}

/// When one session sends the card: once it opens, then when the hour changes. The same bytes are not sent again,
/// and a write waits out the stub's one per 60 s.
public struct CardSchedule: Sendable {
    private var hour: Date?, sent: Data?, wait: Date?

    public init() {}

    /// `hour`: the start of the hour that contains `now`.
    public func due(hour: Date, now: Date) -> Bool { hour != self.hour && wait.map { now >= $0 } ?? true }

    /// true: `card` is what this session wrote last, so this hour is done without a request.
    public mutating func unchanged(_ card: Data, hour: Date) -> Bool {
        guard card == sent else { return false }
        self.hour = hour
        return true
    }

    /// What became of the attempt; `result` nil: no card or no answer, tried again in 5 min.
    public mutating func settle(_ result: PushResult?, card: Data?, hour: Date, now: Date) {
        switch result {
        case .ok?:
            (self.hour, sent) = (hour, card)
            wait = now.addingTimeInterval(60)
        case .later(let ms)?: wait = now.addingTimeInterval(Double(ms) / 1000)
        case .refused?, nil: wait = now.addingTimeInterval(300)
        }
    }
}
