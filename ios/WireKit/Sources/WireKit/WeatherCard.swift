import Foundation

// Weather's widget card, kept fresh by the phone (stub 9, docs/miniapp-rpc.md "Weather's card"): now and the next three
// hours as a v2 `columns` record, the same bytes the Weather app writes from the same answer. It is built from the
// `weather` RPC's own records, so both sides round, clamp and count the hours alike.

/// The store's package that gets the card.
public let weatherPackage = "weather"

/// A forecast's hours from the one that contains `now`, counted on the phone's clock: a cached copy may start hours
/// back. nil when every hour of it has passed.
public func currentHours(_ forecast: [(start: Date, hour: WeatherHour)], now: Date, calendar: Calendar) -> WeatherHours? {
    let thisHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
    let hours = forecast.filter { $0.start >= thisHour }.map(\.hour)
    return hours.isEmpty ? nil : WeatherHours(hour: calendar.component(.hour, from: thisHour), hours: hours)
}

/// The icon's index in Weather's package, its `model::Icon` order: clear, partly, cloud, fog, drizzle, rain, snow,
/// storm. A contract with that package: never reorder.
func weatherIcon(_ code: Int) -> Int {
    switch code {
    case 0: 0
    case 1, 2: 1
    case 45, 48: 3
    case 51...57: 4
    case 61...67, 80...82: 5
    case 71...77, 85, 86: 6
    case 95...99: 7
    default: 2
    }
}

/// Now, then the next three hours after the one that contains now (fewer when fewer are known), from the records
/// `weather` answers. nil without the current record: then the phone writes nothing.
public func weatherCard(_ records: [Data]) -> Data? {
    let records = records.map { [UInt8]($0) }
    guard let now = records.first(where: { $0.first == 0 && $0.count >= 4 }) else { return nil }
    let tenths = Int(Int16(bitPattern: UInt16(now[1]) | UInt16(now[2]) << 8))
    let degrees = tenths >= 0 ? (tenths + 5) / 10 : -((5 - tenths) / 10) // halves away from zero, never "-0"
    var columns = [WidgetColumn(caption: "Now", icon: weatherIcon(Int(now[3])), value: "\(degrees)\u{B0}")]
    if let h = records.first(where: { $0.first == 2 && $0.count >= 2 }) {
        var i = 1 // entry 0 is the hour that contains now
        while i <= 3, 2 + 3 * i + 2 < h.count {
            let at = 2 + 3 * i
            columns.append(WidgetColumn(caption: String(format: "%02d:00", (Int(h[1]) + i) % 24),
                                        icon: weatherIcon(Int(h[at + 1])), value: "\(Int8(bitPattern: h[at]))\u{B0}"))
            i += 1
        }
    }
    return columnsRecord(columns)
}

/// Weather's slot when the phone may push its card: stub 9 or later, the app on the watch by its package name and
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
