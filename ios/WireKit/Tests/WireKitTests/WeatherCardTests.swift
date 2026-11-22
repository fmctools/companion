import Foundation
import Testing
@testable import WireKit

// Weather's card (docs/miniapp-rpc.md, "Weather's card"): push-vectors.json, shared with Android.

@Test func weatherCardFromForecast() throws {
    let p = try PushVectors.load()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let format = DateFormatter()
    (format.calendar, format.timeZone, format.locale) = (calendar, calendar.timeZone, Locale(identifier: "en_US_POSIX"))
    format.dateFormat = "yyyy-MM-dd'T'HH:mm"
    for c in p.weather_cards {
        let start = try #require(format.date(from: c.start)), at = try #require(format.date(from: c.at))
        let forecast = c.hours.enumerated().map { i, h in
            (start: start.addingTimeInterval(Double(i) * 3600),
             hour: WeatherHour(temp: h[0], code: Int(h[1]), precip: 100, night: h.count > 2)) // 100 shares its byte with night
        }
        var records = c.now.map { [weatherRecord(WeatherNow(temp: $0[0], code: Int($0[1]), wind: 0, humidity: 0, ageMin: 0))] } ?? []
        if let hours = currentHours(forecast, now: at, calendar: calendar), let r = weatherRecord(hours, limit: 4) {
            records.append(r)
        }
        let hour = calendar.component(.hour, from: at)
        #expect(weatherCard(records, hour: hour) == c.hex.map(hex), "\(c.note)")
    }
    for i in p.weather_icons {
        #expect(weatherIcon(i[0], night: false) == i[1], "WMO \(i[0])")
        #expect(weatherIcon(i[0], night: true) == i[2], "WMO \(i[0]) at night")
    }
}

@Test func weatherCardGate() {
    let apps = [0: "hello", 15: "weather"]
    #expect(weatherCardSlot(stub: 9, apps: apps, granted: true) == 15)
    #expect(weatherCardSlot(stub: 8, apps: apps, granted: true) == nil, "stub 8: no card, and no v1 in its place")
    #expect(weatherCardSlot(stub: 9, apps: apps, granted: false) == nil)
    #expect(weatherCardSlot(stub: 9, apps: [0: "hello", 1: "weather2"], granted: true) == nil)
    #expect(weatherCardSlot(stub: 9, apps: [16: "weather", 0xFF: "weather"], granted: true) == nil, "slots 0…15 only")
}

@Test func weatherCardSchedule() {
    let t = Date(timeIntervalSince1970: 1_795_000_000), one = t, two = t + 3600, three = t + 7200
    let a = Data([1]), b = Data([2])
    var s = CardSchedule()
    #expect(s.due(hour: one, now: t), "on connect")
    s.settle(.ok, card: a, hour: one, now: t)
    #expect(!s.due(hour: one, now: t + 300), "once an hour")
    #expect(!s.due(hour: two, now: t + 59), "the stub takes one write per 60 s")
    #expect(s.due(hour: two, now: t + 60))
    var same = s
    let repeated = same.unchanged(a, hour: two)
    #expect(repeated && !same.due(hour: two, now: t + 600), "the same bytes: no repeat")
    var skipped = s.unchanged(b, hour: two)
    #expect(!skipped && s.due(hour: two, now: t + 60))
    s.settle(.later(ms: 7000), card: b, hour: two, now: t + 60)
    #expect(!s.due(hour: two, now: t + 66) && s.due(hour: two, now: t + 67), "Later: after the wait it names")
    skipped = s.unchanged(b, hour: two)
    #expect(!skipped, "Later wrote nothing")
    s.settle(nil, card: nil, hour: two, now: t + 67)
    #expect(!s.due(hour: three, now: t + 366) && s.due(hour: three, now: t + 367), "no card: again in 5 min")
    s.settle(.refused(7), card: b, hour: three, now: t + 367)
    skipped = s.unchanged(b, hour: three)
    #expect(!skipped && !s.due(hour: three, now: t + 666) && s.due(hour: three, now: t + 667))
    #expect(CardSchedule().due(hour: one, now: t), "a new session sends again")
}
