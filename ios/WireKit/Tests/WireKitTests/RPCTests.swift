import Foundation
import Testing
@testable import WireKit

/// rpc-vectors.json: the byte layouts of docs/miniapp-rpc.md, shared with Android and the watch apps.
struct RPCVectors: Decodable {
    struct Req: Decodable { let hex: String; let id: UInt8?; let method: UInt8?; let args: String?; let rpc: Bool?; let bad: Bool? }
    struct Cut: Decodable { let text: String; let max: Int; let hex: String }
    struct Cal: Decodable {
        struct In: Decodable {
            let day: Int, start: Int, duration: Int, all_day: Bool, tentative: Bool, color: UInt16, title: String
            let show: Bool
        }
        let `in`: In; let hex: String
    }
    struct CalDate: Decodable {
        let tz: String, now: String, start: String, end: String, day: Int, start_min: Int, duration: Int
    }
    struct Loc: Decodable {
        struct In: Decodable { let lat: Double, lon: Double, age_min: Int, place: String }
        let `in`: In; let hex: String
    }
    struct Weather: Decodable {
        struct In: Decodable {
            let kind: String; let temp: Double?; let code: Int?; let wind: Double?; let humidity: Int?; let age_min: Int?
            let day: Int?; let min: Double?; let max: Double?; let precip: Int?
            struct Hour: Decodable { let temp: Double; let code: Int; let precip: Int; let night: Bool }
            let hour: Int?; let hours: [Hour]?
        }
        let `in`: In; let hex: String
    }
    struct WeatherArgs: Decodable { let args: String; let days: Int?; let hours: Int?; let bad: Bool? }
    let weather_args: [WeatherArgs]
    struct Http: Decodable {
        struct In: Decodable { let code: Int; let body: String }
        let `in`: In; let records: [String]
    }
    struct HttpReq: Decodable {
        struct R: Decodable { let method: String, url: String, body: String }
        let note: String; let messages: [String]; let request: R?; let bad: Bool?
    }
    struct Storage: Decodable {
        struct Key: Decodable { let key: String; let ok: Bool }
        struct Put: Decodable { let note: String; let messages: [String]; let key: String; let value: String }
        struct Get: Decodable { let value: String; let records: [String] }
        let keys: [Key]; let put: [Put]; let get: [Get]; let quota: Int
    }
    struct Notif: Decodable {
        struct In: Decodable { let age_min: Int, app: String, text: String, show: Bool }
        let `in`: In; let hex: String
    }
    struct Reply: Decodable { let id: UInt8; let status: UInt8; let records: [String]; let messages: [String] }
    let requests: [Req]
    let utf8_cut: [Cut]
    let calendar: [Cal]
    let calendar_dates: [CalDate]
    let location: [Loc]
    let weather: [Weather]
    let http: [Http]
    let http_request: [HttpReq]
    let storage: Storage
    struct Battery: Decodable { struct In: Decodable { let level: Int; let charging: Bool }; let `in`: In; let hex: String }
    let battery: [Battery]
    struct Notify: Decodable {
        struct A: Decodable { let title: String; let body: String; let sound: Bool; let find: Bool }
        let args: String; let alert: A?; let bad: Bool?
    }
    let notify: [Notify]
    struct Reminders: Decodable {
        struct ID: Decodable { let id: String; let short: UInt32 }
        struct In: Decodable { let id: String; let day: Int?; let minute: Int?; let color: UInt16; let title: String; let show: Bool }
        struct Rec: Decodable { let `in`: In; let hex: String }
        struct OrderIn: Decodable { let title: String; let day: Int?; let minute: Int?; let list: String }
        struct Order: Decodable { let `in`: [OrderIn]; let titles: [String] }
        let ids: [ID]; let records: [Rec]; let order: Order
    }
    let reminders: Reminders
    struct Media: Decodable {
        struct In: Decodable { let playing: Bool; let position: Int?; let duration: Int?; let app: String; let title: String; let artist: String }
        let `in`: In; let hex: String
    }
    let media: [Media]
    struct Job: Decodable {
        struct J: Decodable { let id: Int; let minutes: Int; let kind: Int; let target: Int; let spec: String; let cap: String }
        let payload: String; let job: J?; let bad: Bool?; let note: String?
    }
    let jobs: [Job]
    let notifications: [Notif]
    let replies: [Reply]

    static let shared: RPCVectors = {
        let url = Bundle.module.url(forResource: "rpc-vectors", withExtension: "json")!
        return try! JSONDecoder().decode(RPCVectors.self, from: Data(contentsOf: url))
    }()
}

private let rv = RPCVectors.shared

@Test func rpcRequests() {
    for r in rv.requests {
        let got = parseRequest(hex(r.hex))
        if r.rpc == false {
            #expect(got == nil, "\(r.hex)")
        } else if r.bad == true {
            #expect(got == .bad(id: hex(r.hex)[3]), "\(r.hex)")
        } else {
            #expect(got == .call(id: r.id!, method: r.method!, args: hex(r.args!)), "\(r.hex)")
        }
    }
}

@Test func rpcUtf8Cut() {
    for c in rv.utf8_cut { #expect(utf8Cut(c.text, c.max) == hex(c.hex), "\(c.text)") }
    #expect(utf8Cut(String(repeating: "a", count: 65), 64).count == 64)
}

@Test func rpcCalendarRecords() {
    for c in rv.calendar {
        let i = c.in
        let e = CalendarEvent(day: i.day, start: i.start, duration: i.duration, allDay: i.all_day,
                              tentative: i.tentative, color: i.color, title: i.title)
        #expect(calendarRecord(e, show: i.show) == hex(c.hex), "\(i.title)")
    }
}

@Test func rpcCalendarDates() {
    for c in rv.calendar_dates {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: c.tz)!
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let e = CalendarEvent(start: f.date(from: c.start)!, end: f.date(from: c.end)!, allDay: false,
                              now: f.date(from: c.now)!, calendar: cal, tentative: false, color: 0, title: "")
        #expect([e.day, e.start, e.duration] as [Int] == [c.day, c.start_min, c.duration], "\(c.tz) \(c.start)")
    }
}

@Test func rpcAllDaySpansDays() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
    let start = cal.date(from: DateComponents(year: 2026, month: 3, day: 28))!
    // EventKit's end of a 2-day all-day event over the DST change: 23:59:59 of the second day
    let end = cal.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 23, minute: 59, second: 59))!
    let e = CalendarEvent(start: start, end: end, allDay: true, now: start, calendar: cal, tentative: false, color: 0,
                          title: "")
    #expect([e.day, e.start, e.duration] as [Int] == [0, 0, 2880])
}

@Test func rpcLocationWeatherNotifications() {
    for l in rv.location {
        #expect(locationRecord(LocationFix(lat: l.in.lat, lon: l.in.lon, ageMin: l.in.age_min, place: l.in.place))
            == hex(l.hex))
    }
    for w in rv.weather {
        let i = w.in
        let got: Data? = switch i.kind {
        case "now": weatherRecord(WeatherNow(temp: i.temp!, code: i.code!, wind: i.wind!, humidity: i.humidity!,
                                             ageMin: i.age_min!))
        case "hours": weatherRecord(WeatherHours(hour: i.hour!, hours: i.hours!.map {
            WeatherHour(temp: $0.temp, code: $0.code, precip: $0.precip, night: $0.night) }), limit: 24)
        default: weatherRecord(WeatherDay(day: i.day!, min: i.min!, max: i.max!, code: i.code!, precip: i.precip!))
        }
        #expect(got == hex(w.hex), "\(i.kind)")
    }
    for a in rv.weather_args {
        let got = weatherArgs(hex(a.args))
        if a.bad == true { #expect(got == nil, "\(a.args)") } else {
            #expect(got?.days == a.days && got?.hours == a.hours, "\(a.args)")
        }
    }
    let two = WeatherHours(hour: 23, hours: (0..<30).map { WeatherHour(temp: Double($0), code: 0, precip: 0, night: false) })
    #expect(weatherRecord(two, limit: 2) == Data([2, 23, 0, 0, 0, 1, 0, 0]), "cut to the hours asked")
    #expect(weatherRecord(two, limit: 30)?.count == 2 + 24 * 3, "never over 24")
    #expect(weatherRecord(two, limit: 0) == nil && weatherRecord(WeatherHours(hour: 0, hours: []), limit: 5) == nil)
    #expect(weatherRecord(WeatherHours(hour: 0, hours: [WeatherHour(temp: -200, code: 0, precip: 130, night: true)]), limit: 1)
        == Data([2, 0, 0x80, 0, 0x80 | 100]), "temp and precip clamped")
}

@Test @MainActor func rpcWeatherHours() async throws {
    let h = FakeHost()
    h.given["weather.app"] = ["weather": true]
    let r = await ask(h, call(RPCMethod.weather, [3, 12]))
    #expect(r?.0 == .ok)
    #expect(r?.1.map { $0[0] } == [0, 2, 1, 1, 1], "current, hourly, then the days")
    #expect(r?.1[1].count == 2 + 12 * 3)
    #expect(await ask(h, call(RPCMethod.weather, [3]))?.1.map { $0[0] } == [0, 1, 1, 1], "no hours unless asked")
    #expect(await ask(h, call(RPCMethod.weather, [3, 25]))?.0 == .badRequest)
    h.noHours = true
    #expect(await ask(h, call(RPCMethod.weather, [1, 12]))?.1.map { $0[0] } == [0, 1], "the source has no hours")
    for n in rv.notifications {
        let i = n.in
        #expect(notificationRecord(PhoneNotification(ageMin: i.age_min, app: i.app, text: i.text), show: i.show)
            == hex(n.hex))
    }
}

@Test func rpcHttpRecords() throws {
    for h in rv.http {
        #expect(try httpRecords(code: h.in.code, body: hex(h.in.body)) == h.records.map(hex))
    }
    #expect(throws: RPCStatus.tooLarge) { try httpRecords(code: 200, body: Data(count: 2049)) }
}

/// Each case to fresh parts: no reply before the last message, then the joined request or BAD_REQUEST.
@Test @MainActor func rpcHttpRequestVectors() {
    for c in rv.http_request {
        let parts = RequestParts()
        var joined: Data?
        var bad = false
        for (i, m) in c.messages.enumerated() {
            guard case .call(let id, let method, let args)? = parseRequest(hex(m)) else { bad = true; break }
            #expect(method == RPCMethod.httpRequest, "\(c.note)")
            do {
                joined = try parts.add("a", id: id, args: args)
                #expect((joined == nil) == (i < c.messages.count - 1), "\(c.note): reply only after the last part")
            } catch {
                #expect(i == c.messages.count - 1, "\(c.note): only the last message is refused")
                bad = true
            }
        }
        let call = joined.flatMap(parseHTTPCall)
        if c.bad == true {
            #expect(bad || call == nil, "\(c.note)")
        } else {
            #expect(call == HTTPCall(method: c.request!.method, url: URL(string: c.request!.url)!, body: hex(c.request!.body)),
                    "\(c.note)")
        }
    }
}

@Test func rpcRequestHeaders() {
    let auth = HTTPHeader(name: "Authorization", value: "Bearer x")
    let json = HTTPHeader(name: "Content-Type", value: "application/json")
    #expect(requestHeaders([auth], body: Data("{}".utf8)) == [auth, json])
    #expect(requestHeaders([auth], body: Data("[1]".utf8)) == [auth, json])
    #expect(requestHeaders([auth], body: Data("a=1".utf8)) == [auth])
    #expect(requestHeaders([], body: Data()) == [])
    let mine = HTTPHeader(name: "content-type", value: "text/plain")
    #expect(requestHeaders([mine], body: Data("{}".utf8)) == [mine], "the user's own Content-Type wins")
    #expect(requestHeaders([HTTPHeader(name: " ", value: "x")], body: Data()) == [], "unnamed rows dropped")
}

@Test func rpcReplies() {
    for r in rv.replies {
        #expect(replies(id: r.id, status: RPCStatus(rawValue: r.status)!, records: r.records.map(hex))
            == r.messages.map(hex))
    }
}

// MARK: dispatcher

@MainActor final class FakeHost: RPCHost {
    var given: [String: [String: Bool]] = [:]
    var asked: [String] = []
    var osOff: Set<String> = []
    var show = false
    var notificationsAvailable = false
    var events: [CalendarEvent] = []
    var slow = false

    func grants(_ package: String) -> [String: Bool] { given[package] ?? [:] }
    var writes: [Bool] = []
    let state = RPCState(storage: KeyValueStore(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("rpc-tests-\(UUID().uuidString)")))
    var calls: [HTTPCall] = []
    func ask(_ package: String, _ cap: String, write: Bool) { asked.append("\(package) \(cap)"); writes.append(write) }
    func osAllowed(_ cap: String) -> Bool { !osOff.contains(cap) }
    func showText(_ package: String) -> Bool { show }
    func calendar(fromDay: Int, days: Int) async throws -> [CalendarEvent] {
        if slow { try? await Task.sleep(for: .seconds(5)) }
        return events
    }
    func location() async throws -> LocationFix { throw RPCStatus.unavailable }
    var noHours = false
    func weather() async throws -> (now: WeatherNow, hours: WeatherHours?, days: [WeatherDay]) {
        (WeatherNow(temp: 1, code: 0, wind: 1, humidity: 50, ageMin: 0),
         noHours ? nil : WeatherHours(hour: 22, hours: (0..<48).map { WeatherHour(temp: Double($0), code: 3, precip: 10, night: $0 < 9) }),
         (0..<10).map { WeatherDay(day: $0, min: 0, max: 1, code: 0, precip: 0) })
    }
    func http(_ call: HTTPCall, package: String) async throws -> (code: Int, body: Data) {
        calls.append(call)
        return (200, Data("ok".utf8))
    }
    func notifications(limit: Int) async throws -> [PhoneNotification] { [] }
    func battery() async throws -> (level: Int, charging: Bool) { (57, true) }
    var alerts: [PhoneAlert] = []
    func notify(_ package: String, _ alert: PhoneAlert) async throws { alerts.append(alert) }
    var todo: [PhoneReminder] = []
    func reminders() async throws -> [PhoneReminder] { todo }
    func completeReminder(_ id: String) async throws { todo.removeAll { $0.id == id } }
    var jobs: [String: [RefreshJob]] = [:]
    func saveJob(_ package: String, _ job: RefreshJob) { jobs[package, default: []].removeAll { $0.id == job.id }; jobs[package]!.append(job) }
    func deleteJob(_ package: String, _ id: Int) { jobs[package]?.removeAll { $0.id == id } }
}

private func call(_ method: UInt8, _ args: [UInt8] = [], id: UInt8 = 1) -> Data {
    Data("R1Q".utf8) + [id, method] + args
}

/// (status, records) of the replies.
private func ask(_ host: FakeHost, _ m: Data, package: String? = "weather.app",
                 deadline: Duration = .seconds(7)) async -> (RPCStatus, [Data])? {
    guard let r = await answer(m, package: package, host: host, deadline: deadline) else { return nil }
    return (RPCStatus(rawValue: r[0][4])!, r[0][7...].isEmpty && r[0][6] == 0 ? [] : r.map { Data($0.dropFirst(7)) })
}

@Test @MainActor func rpcAsksDeniesAndRuns() async throws {
    let h = FakeHost()
    let cal = call(RPCMethod.calendar, [0, 1, 5])
    #expect(await ask(h, cal)?.0 == .ask)
    #expect(h.asked == ["weather.app calendar"])
    #expect(await ask(h, call(RPCMethod.caps))?.1 == [storageIDs])

    h.given["weather.app"] = ["calendar": false]
    #expect(await ask(h, cal)?.0 == .denied)
    #expect(h.asked.count == 1, "no new notification once answered")

    h.given["weather.app"] = ["calendar": true, "http:example.com": true]
    h.osOff = ["calendar"]
    #expect(await ask(h, cal)?.0 == .denied, "OS permission off")
    #expect(await ask(h, call(RPCMethod.caps))?.1 == [Data([RPCMethod.http, RPCMethod.httpRequest]) + storageIDs])

    h.osOff = []
    h.events = [
        CalendarEvent(day: 1, start: 0, duration: 1440, allDay: true, tentative: false, color: 0, title: "b"),
        CalendarEvent(day: 0, start: 600, duration: 30, allDay: false, tentative: false, color: 0, title: "a"),
        CalendarEvent(day: 1, start: 60, duration: 30, allDay: false, tentative: false, color: 0, title: "c"),
    ]
    let (s, records) = try #require(await ask(h, call(RPCMethod.calendar, [0, 9, 2])))
    #expect(s == .ok)
    #expect(records.map { $0[0] } == [0, 1], "sorted, all-day first in a day, cut to limit")
    #expect(records.allSatisfy { $0[5] & 4 != 0 && $0.count == 8 }, "text hidden by default")
    #expect(await ask(h, call(RPCMethod.caps))?.1 == [Data([RPCMethod.calendar, RPCMethod.http, RPCMethod.httpRequest]) + storageIDs])
}

@Test @MainActor func rpcBadRequests() async {
    let h = FakeHost()
    #expect(await ask(h, call(0x7F))?.0 == .badRequest)
    #expect(await ask(h, call(RPCMethod.calendar, [0]))?.0 == .badRequest)
    #expect(await ask(h, call(RPCMethod.http, Array("http://example.com/".utf8)))?.0 == .badRequest)
    #expect(await ask(h, Data("R1Q".utf8) + [3])?.0 == .badRequest)
    #expect(await ask(h, Data("R1P\u{1}\u{0}".utf8)) == nil)
    #expect(await ask(h, Data("hello".utf8)) == nil)
    #expect(await ask(h, call(RPCMethod.notifications, [3]))?.0 == .unavailable, "iOS has none")
    #expect(h.asked.isEmpty)
    #expect(await ask(h, call(RPCMethod.caps), package: nil)?.0 == .unavailable, "slot not read")
}

@Test @MainActor func rpcHttpWeatherAndDeadline() async throws {
    let h = FakeHost()
    let get = call(RPCMethod.http, Array("https://Example.com/a?b=1".utf8))
    #expect(await ask(h, get)?.0 == .ask)
    #expect(h.asked == ["weather.app http:example.com"])
    h.given["weather.app"] = ["http:example.com": true, "weather": true, "calendar": true]
    #expect(await ask(h, get)?.1 == [Data([200, 0, 2, 0]), Data("ok".utf8)])
    #expect(await ask(h, call(RPCMethod.weather, [3]))?.1.map { $0[0] } == [0, 1, 1, 1])
    #expect(await ask(h, call(RPCMethod.weather, [99]))?.1.count == 8, "days clamped to 7")
    h.slow = true
    #expect(await ask(h, call(RPCMethod.calendar, [0, 1, 1]), deadline: .milliseconds(200))?.0 == .unavailable)
}

@Test @MainActor func rpcHttpRequestDispatch() async throws {
    let h = FakeHost()
    let body = Data(#"{"a":1}"#.utf8)
    let payload = Data([1, 20]) + Data("https://example.com/".utf8) + body
    let one = call(RPCMethod.httpRequest, [0, 1] + Array(payload), id: 4)
    #expect(await ask(h, one)?.0 == .ask)
    #expect(h.asked == ["weather.app http:example.com"] && h.writes == [true], "the ask says it can change data")
    h.given["weather.app"] = ["http:example.com": true]
    #expect(await ask(h, one)?.1 == [Data([200, 0, 2, 0]), Data("ok".utf8)])
    #expect(h.calls == [HTTPCall(method: "POST", url: URL(string: "https://example.com/")!, body: body)])

    // two parts: nothing after the first, the reply after the second
    let a = call(RPCMethod.httpRequest, [0, 2] + Array(payload.prefix(10)), id: 5)
    let b = call(RPCMethod.httpRequest, [1, 2] + Array(payload.dropFirst(10)), id: 5)
    #expect(await answer(a, package: "weather.app", host: h) == [])
    #expect(await ask(h, b)?.0 == .ok)
    #expect(h.calls.count == 2 && h.calls[1].body == body)
    // a new id before the last part
    #expect(await answer(a, package: "weather.app", host: h) == [])
    #expect(await ask(h, call(RPCMethod.httpRequest, [1, 2] + Array(payload.dropFirst(10)), id: 6))?.0 == .badRequest)
    #expect(await ask(h, b)?.0 == .badRequest, "the dropped request doesn't come back")
    // parts are per package
    #expect(await answer(a, package: "weather.app", host: h) == [])
    #expect(await answer(a, package: "other.app", host: h) == [])
    #expect(await ask(h, b)?.0 == .ok)
}

/// Methods every package may call, at the end of `caps`.
let storageIDs = Data(RPCMethod.free)

@Test @MainActor func rpcBattery() async {
    for b in rv.battery { #expect(batteryRecord(level: b.in.level, charging: b.in.charging) == hex(b.hex)) }
    let h = FakeHost()
    #expect(await ask(h, call(RPCMethod.battery))?.1 == [Data([57, 1])])
    #expect(h.asked.isEmpty, "no cap")
}

@Test @MainActor func rpcStorageVectors() async throws {
    let st = rv.storage
    #expect(st.quota == KeyValueStore.quota)
    for k in st.keys { #expect(((try? storageKey(hex(k.key))) != nil) == k.ok, "\(k.key)") }
    for g in st.get { #expect(valueRecords(hex(g.value)) == g.records.map(hex)) }
    let h = FakeHost()
    for c in st.put {
        for (i, m) in c.messages.enumerated() {
            let r = try #require(await answer(hex(m), package: "app", host: h))
            if i < c.messages.count - 1 { #expect(r.isEmpty, "\(c.note)") } else { #expect(r == replies(id: hex(m)[3], status: .ok, records: []), "\(c.note)") }
        }
        #expect(h.state.storage.get("app", c.key) == hex(c.value), "\(c.note)")
        let got = await ask(h, call(RPCMethod.storageGet, Array(c.key.utf8)), package: "app")
        #expect(got?.0 == .ok && got?.1 == (c.value.isEmpty ? [Data([0, 0])] : valueRecords(hex(c.value))), "\(c.note)")
    }
    #expect(await ask(h, call(RPCMethod.storageGet, Array("nope".utf8)), package: "app")?.1 == [], "missing: no records")
    #expect(await ask(h, call(RPCMethod.storageGet, Array("score".utf8)), package: "other")?.1 == [], "per package")
    #expect(await ask(h, call(RPCMethod.storageDelete, Array("score".utf8)), package: "app")?.0 == .ok)
    #expect(h.state.storage.get("app", "score") == nil)
    #expect(await ask(h, call(RPCMethod.storageGet, Array("a/b".utf8)), package: "app")?.0 == .badRequest)
    #expect(h.asked.isEmpty, "no cap")
}

@Test func rpcStorageQuota() throws {
    let s = KeyValueStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("quota-\(UUID().uuidString)"))
    try s.put("p", "a", Data(count: 40_000))
    #expect(throws: RPCStatus.tooLarge) { try s.put("p", "b", Data(count: 30_000)) }
    try s.put("p", "a", Data(count: 60_000)) // replacing counts the new size only
    #expect(s.used("p") == 60_001)
    try s.put("q", "b", Data(count: 30_000)) // another package has its own quota
    s.clear("p")
    #expect(s.get("p", "a") == nil && s.get("q", "b") != nil)
}

@Test @MainActor func rpcNotify() async {
    for n in rv.notify {
        let got = parseAlert(hex(n.args))
        if n.bad == true { #expect(got == nil, "\(n.args)") } else {
            let a = n.alert!
            #expect(got == PhoneAlert(title: a.title, body: a.body, sound: a.sound, find: a.find), "\(n.args)")
        }
    }
    let h = FakeHost()
    var t = Date(timeIntervalSince1970: 0)
    h.state.now = { t }
    let m = call(RPCMethod.notify, Array(hex(rv.notify[0].args)))
    #expect(await ask(h, m)?.0 == .ask)
    #expect(h.asked == ["weather.app notify"])
    h.given["weather.app"] = ["notify": true]
    #expect(await ask(h, m)?.0 == .ok)
    #expect(h.alerts.count == 1 && h.alerts[0].title == "Timer")
    t += 5
    #expect(await ask(h, m)?.0 == .unavailable, "one per 10 s")
    #expect(await ask(h, m, package: "other.app")?.0 == .ask, "per package")
    t += 6
    #expect(await ask(h, m)?.0 == .ok)
    #expect(await ask(h, call(RPCMethod.notify, [0, 9]))?.0 == .badRequest)
    #expect(await ask(h, call(RPCMethod.caps))?.1 == [Data([RPCMethod.notify]) + storageIDs])
}

@Test @MainActor func rpcReminders() async throws {
    let r = rv.reminders
    for i in r.ids { #expect(shortID(i.id) == i.short, "\(i.id)") }
    for c in r.records {
        let i = c.in
        #expect(reminderRecord(PhoneReminder(id: i.id, dueDay: i.day, dueMinute: i.minute, list: "", color: i.color,
                                             title: i.title), show: i.show) == hex(c.hex), "\(i.title)")
    }
    let order = r.order.in.map { PhoneReminder(id: $0.title, dueDay: $0.day, dueMinute: $0.minute, list: $0.list, color: 0, title: $0.title) }
    #expect(sortReminders(order).map(\.title) == r.order.titles)

    let h = FakeHost()
    h.todo = order
    #expect(await ask(h, call(RPCMethod.reminders, [3]))?.0 == .ask)
    h.given["weather.app"] = ["reminders": true]
    let got = try #require(await ask(h, call(RPCMethod.reminders, [3])))
    #expect(got.0 == .ok && got.1.count == 3 && got.1.allSatisfy { $0[7] & 4 != 0 }, "limit, text hidden by default")
    var id = Data()
    id.le(shortID("e"))
    #expect(await ask(h, call(RPCMethod.reminderDone, Array(id)))?.0 == .ok)
    #expect(!h.todo.contains { $0.title == "e" })
    #expect(await ask(h, call(RPCMethod.reminderDone, Array(id)))?.0 == .badRequest, "no such reminder now")
    #expect(await ask(h, call(RPCMethod.caps))?.1 == [Data([RPCMethod.reminders, RPCMethod.reminderDone]) + storageIDs])
}

@Test @MainActor func rpcMedia() async {
    for m in rv.media {
        let i = m.in
        #expect(mediaRecord(NowPlaying(playing: i.playing, position: i.position, duration: i.duration, app: i.app,
                                       title: i.title, artist: i.artist)) == hex(m.hex), "\(i.title)")
    }
    let h = FakeHost()
    #expect(await ask(h, call(RPCMethod.media))?.0 == .unavailable, "iOS has no other apps' players")
    #expect(await ask(h, call(RPCMethod.mediaControl, [2]))?.0 == .unavailable)
    #expect(h.asked.isEmpty)
}

@Test @MainActor func rpcJobs() async throws {
    for c in rv.jobs {
        let got = parseJob(hex(c.payload))
        if c.bad == true { #expect(got == nil, "\(c.note ?? c.payload)") } else {
            let j = c.job!
            #expect(got == RefreshJob(id: j.id, minutes: j.minutes, kind: JobKind(rawValue: j.kind)!,
                                      target: PushKind(rawValue: j.target)!, spec: hex(j.spec)), "\(c.payload)")
            #expect(got?.cap == j.cap)
        }
    }
    var j = RefreshJob(id: 0, minutes: 15, kind: .weather, spec: Data([3]))
    let t0 = Date(timeIntervalSince1970: 1000)
    #expect(j.due(t0), "never run: due")
    j.last = t0
    #expect(!j.due(t0 + 14 * 60) && j.due(t0 + 15 * 60))
    j.on = false
    #expect(!j.due(t0 + 3600), "switched off")

    let h = FakeHost()
    let set = call(RPCMethod.jobSet, [0, 1] + Array(hex(rv.jobs[0].payload)), id: 3)
    #expect(await ask(h, set)?.0 == .ask, "the job asks for its cap")
    #expect(h.asked == ["weather.app http:api.example.com"])
    h.given["weather.app"] = ["http:api.example.com": true, "weather": true]
    #expect(await ask(h, set)?.0 == .ok)
    let job = try #require(h.jobs["weather.app"]?.first)
    #expect(try await runJob(job, package: "weather.app", host: h) == [Data([200, 0, 2, 0]), Data("ok".utf8)])
    #expect(try await runJob(RefreshJob(id: 1, minutes: 15, kind: .weather, spec: Data([2])), package: "weather.app", host: h).count == 3)
    h.given["weather.app"] = ["weather": true]
    await #expect(throws: RPCStatus.denied) { try await runJob(job, package: "weather.app", host: h) }
    #expect(await ask(h, call(RPCMethod.jobDelete, [0]))?.0 == .ok)
    #expect(h.jobs["weather.app"] == [])
}

/// WeatherKit starts a day at midnight at the place; the watch counts days on the phone's clock.
@Test func forecastDayOnPhoneClock() {
    func cal(_ id: String) -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: id)!; return c }
    func midnight(_ day: Int, _ id: String) -> Date { cal(id).date(from: DateComponents(year: 2026, month: 11, day: day))! }
    let now = midnight(22, "America/New_York") + 10 * 3600 // 10:00 on the 22nd in New York
    for zone in ["America/New_York", "Europe/London", "Europe/Moscow", "America/Los_Angeles", "Pacific/Honolulu"] {
        let ny = cal("America/New_York")
        #expect(forecastDay(midnight(22, zone), now: now, calendar: ny) == 0, "\(zone)")
        #expect(forecastDay(midnight(23, zone), now: now, calendar: ny) == 1, "\(zone)")
    }
}
