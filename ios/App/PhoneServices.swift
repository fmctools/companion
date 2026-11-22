import CoreLocation
import EventKit
import UIKit
import UserNotifications
import WeatherKit
import WireKit

// The phone's side of the miniapp services (docs/miniapp-rpc.md, "Methods"): EventKit, CoreLocation, WeatherKit,
// URLSession. Grants come from Permissions; the byte layouts and the dispatcher live in WireKit (RPC.swift).

@MainActor final class PhoneServices: NSObject, RPCHost {
    static let shared = PhoneServices()

    private var events = EKEventStore()
    private let locations = CLLocationManager()
    private var fix: CheckedContinuation<Void, Never>?
    /// rounded coordinate → locality
    private var places: [String: String] = [:]
    /// `located`: from a fresh fix, or one that was asked for. Otherwise only the card reuses it.
    private var cached: (at: Date, located: Bool, now: CurrentWeather, hours: [HourWeather], days: [DayWeather])?

    override init() {
        super.init()
        locations.delegate = self
        locations.desiredAccuracy = kCLLocationAccuracyReduced
    }

    // MARK: grants

    func grants(_ package: String) -> [String: Bool] { Permissions.shared.grants(package) }
    func ask(_ package: String, _ cap: String, write: Bool) { Permissions.shared.ask(package, cap, write: write) }
    let state = RPCState(storage: PhoneServices.storage)

    /// Watch apps' key/value stores (storage, 0x60–0x62): Application Support, kept out of backups.
    static let storage: KeyValueStore = {
        var dir = URL.applicationSupportDirectory.appending(path: "storage", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? dir.setResourceValues(v)
        return KeyValueStore(root: dir)
    }()
    /// "package|host" → the cookies the host set for that app's requests.
    /// ponytail: in memory, gone with the process; Keychain if apps need a login to outlive that.
    private var cookies: [String: [HTTPCookie]] = [:]

    func saveJob(_ package: String, _ job: RefreshJob) { Jobs.shared.set(package, job) }
    func deleteJob(_ package: String, _ id: Int) { Jobs.shared.delete(package, id) }

    func clearCookies(_ package: String) { cookies = cookies.filter { !$0.key.hasPrefix("\(package)|") } }
    func showText(_ package: String) -> Bool { Permissions.shared.showText(package) }
    let notificationsAvailable = false

    func osAllowed(_ cap: String) -> Bool {
        switch cap {
        case "calendar": EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case "reminders": EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        case "location", "weather": [.authorizedWhenInUse, .authorizedAlways].contains(locations.authorizationStatus)
        case "notifications": false
        // ponytail: the system drops a notification the user turned off; no sync read of that here
        case "notify": true
        default: cap.hasPrefix("http:")
        }
    }

    /// Allow on the Permissions screen: the OS prompt for what the cap needs.
    func requestOS(_ cap: String) async {
        switch cap {
        case "calendar":
            _ = try? await events.requestFullAccessToEvents()
            events = EKEventStore() // a store made before the grant sees no calendars
        case "reminders":
            _ = try? await events.requestFullAccessToReminders()
            events = EKEventStore()
        case "location", "weather":
            if locations.authorizationStatus == .notDetermined { locations.requestWhenInUseAuthorization() }
        case "notify":
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        default: break
        }
    }

    // MARK: services

    func calendar(fromDay: Int, days: Int) async throws -> [CalendarEvent] {
        let cal = Calendar.current, now = Date.now
        let start = cal.date(byAdding: .day, value: fromDay, to: cal.startOfDay(for: now))!
        let end = cal.date(byAdding: .day, value: days, to: start)!
        return events.events(matching: events.predicateForEvents(withStart: start, end: end, calendars: nil)).map { e in
            var (r, g, b) = (CGFloat(0), CGFloat(0), CGFloat(0))
            UIColor(cgColor: e.calendar.cgColor).getRed(&r, green: &g, blue: &b, alpha: nil)
            return CalendarEvent(start: e.startDate, end: e.endDate, allDay: e.isAllDay, now: now, calendar: cal,
                                 tentative: e.status == .tentative || e.availability == .tentative,
                                 color: rgb565(r, g, b), title: e.title ?? "")
        }
    }

    func reminders() async throws -> [PhoneReminder] {
        let store = events, cal = Calendar.current, today = cal.startOfDay(for: .now)
        let found: [EKReminder] = await withCheckedContinuation { c in
            store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)) {
                nonisolated(unsafe) let r = $0 ?? []
                c.resume(returning: r)
            }
        }
        return found.map { r in
            var (red, green, blue) = (CGFloat(0), CGFloat(0), CGFloat(0))
            UIColor(cgColor: r.calendar.cgColor).getRed(&red, green: &green, blue: &blue, alpha: nil)
            let due = r.dueDateComponents.flatMap { cal.date(from: $0) }
            let timed = r.dueDateComponents?.hour != nil
            return PhoneReminder(id: r.calendarItemIdentifier,
                                 dueDay: due.flatMap { cal.dateComponents([.day], from: today, to: cal.startOfDay(for: $0)).day },
                                 dueMinute: timed ? due.map { cal.component(.hour, from: $0) * 60 + cal.component(.minute, from: $0) } : nil,
                                 list: r.calendar.title, color: rgb565(red, green, blue), title: r.title ?? "")
        }
    }

    func completeReminder(_ id: String) async throws {
        guard let r = events.calendarItem(withIdentifier: id) as? EKReminder else { throw RPCStatus.badRequest }
        r.isCompleted = true
        try events.save(r, commit: true)
    }

    func location() async throws -> LocationFix {
        let loc = try await lastLocation()
        return LocationFix(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                           ageMin: Int(-loc.timestamp.timeIntervalSinceNow / 60), place: await locality(loc))
    }

    func weather() async throws -> (now: WeatherNow, hours: WeatherHours?, days: [WeatherDay]) {
        try await fetchForecast(locate: true)
        guard let forecast = forecast() else { throw RPCStatus.unavailable }
        return forecast
    }

    /// Weather's card from the same forecast, a stale copy when there's no new one. It never asks for a location
    /// fix: it runs in the background, so the last known one has to do.
    func weatherCardRecord() async -> Data? {
        try? await fetchForecast(locate: false)
        guard let w = forecast() else { return nil }
        let hours = w.hours.flatMap { weatherRecord($0, limit: 4) }
        return weatherCard([weatherRecord(w.now)] + (hours.map { [$0] } ?? []))
    }

    private func fetchForecast(locate: Bool) async throws {
        if let cached, -cached.at.timeIntervalSinceNow <= 30 * 60, cached.located || !locate { return }
        let loc: CLLocation
        if locate {
            loc = try await lastLocation()
        } else {
            guard let last = locations.location else { throw RPCStatus.unavailable }
            loc = last
        }
        let (now, hourly, daily) = try await withDeadline(.seconds(6)) {
            try await WeatherService.shared.weather(for: loc, including: .current, .hourly, .daily)
        }
        cached = (.now, locate || -loc.timestamp.timeIntervalSinceNow <= 15 * 60, now, Array(hourly), Array(daily))
    }

    /// The cached forecast as of now.
    private func forecast() -> (now: WeatherNow, hours: WeatherHours?, days: [WeatherDay])? {
        guard let cached else { return nil }
        let cal = Calendar.current, today = cal.startOfDay(for: .now)
        let c = cached.now
        let now = WeatherNow(temp: c.temperature.converted(to: .celsius).value, code: wmo(c.condition),
                             wind: c.wind.speed.converted(to: .metersPerSecond).value,
                             humidity: Int((c.humidity * 100).rounded()),
                             ageMin: Int(-cached.at.timeIntervalSinceNow / 60))
        let days = cached.days.compactMap { d -> WeatherDay? in
            let day = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: d.date)).day ?? -1
            guard day >= 0 else { return nil }
            return WeatherDay(day: day, min: d.lowTemperature.converted(to: .celsius).value,
                              max: d.highTemperature.converted(to: .celsius).value, code: wmo(d.condition),
                              precip: Int((d.precipitationChance * 100).rounded()))
        }
        let hours = cached.hours.map { h in
            (start: h.date, hour: WeatherHour(temp: h.temperature.converted(to: .celsius).value, code: wmo(h.condition),
                                              precip: Int((h.precipitationChance * 100).rounded()), night: !h.isDaylight))
        }
        return (now, currentHours(hours, now: .now, calendar: cal), days)
    }

    /// With the user's headers for (package, host) and its cookie jar; neither goes to the watch or the log.
    /// ponytail: cookies set on a redirect's own response are not kept.
    func http(_ call: HTTPCall, package: String) async throws -> (code: Int, body: Data) {
        var req = URLRequest(url: call.url, timeoutInterval: 6)
        req.httpMethod = call.method
        req.setValue("FMC-Companion", forHTTPHeaderField: "User-Agent")
        if !call.body.isEmpty { req.httpBody = call.body }
        for h in requestHeaders(Permissions.shared.headers(package, call.host), body: call.body) {
            req.setValue(h.value, forHTTPHeaderField: h.name)
        }
        let key = "\(package)|\(call.host)", path = call.url.path.isEmpty ? "/" : call.url.path
        let jar = (cookies[key] ?? []).filter { ($0.expiresDate ?? .distantFuture) > .now && path.hasPrefix($0.path) }
        for (k, v) in HTTPCookie.requestHeaderFields(with: jar) { req.setValue(v, forHTTPHeaderField: k) }
        let r = try await withDeadline(.seconds(6)) { [req] in
            let (bytes, response) = try await Self.http.bytes(for: req, delegate: SameHost())
            var body = Data()
            for try await b in bytes {
                body.append(b)
                if body.count > 2048 { throw RPCStatus.tooLarge }
            }
            let http = response as? HTTPURLResponse
            let fields = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) {
                if let k = $1.key as? String, let v = $1.value as? String { $0[k] = v }
            }
            return (http?.statusCode ?? 0, body, fields, http?.url ?? req.url!)
        }
        let set = HTTPCookie.cookies(withResponseHeaderFields: r.2, for: r.3)
        if !set.isEmpty {
            cookies[key] = (cookies[key] ?? []).filter { c in !set.contains { $0.name == c.name && $0.path == c.path } } + set
        }
        return (r.0, r.1)
    }

    func notifications(limit: Int) async throws -> [PhoneNotification] { throw RPCStatus.unavailable }

    /// A local notification with the default sound, or none. "Find my phone" is the same with its sound on: critical
    /// alerts need Apple's entitlement and iOS gives a background app no way to play its own audio.
    func notify(_ package: String, _ alert: PhoneAlert) async throws {
        let app = StoreApps.shared.listing(package)?.name ?? package
        let n = UNMutableNotificationContent()
        n.title = alert.find ? String(localized: "Find my phone") : alert.title.isEmpty ? app : alert.title
        n.body = alert.find && alert.body.isEmpty ? String(localized: "\(app) on your watch is looking for this phone.") : alert.body
        if alert.sound || alert.find { n.sound = .default }
        n.userInfo = ["package": package]
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "notify-\(package)-\(UUID().uuidString)", content: n, trigger: nil))
    }

    func battery() async throws -> (level: Int, charging: Bool) {
        let d = UIDevice.current
        d.isBatteryMonitoringEnabled = true
        guard d.batteryLevel >= 0 else { throw RPCStatus.unavailable } // the simulator, or unknown
        return (Int((d.batteryLevel * 100).rounded()), d.batteryState == .charging || d.batteryState == .full)
    }

    private static let http: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.timeoutIntervalForRequest = 6
        return URLSession(configuration: c)
    }()

    // MARK: location

    /// The last known fix; a fresh one first when it is over 15 min old and one comes within 3 s (foreground, or
    /// whatever When In Use allows in the background).
    private func lastLocation() async throws -> CLLocation {
        if osAllowed("location"), locations.location.map({ -$0.timestamp.timeIntervalSinceNow > 15 * 60 }) ?? true {
            await refresh(within: .seconds(3))
        }
        guard let loc = locations.location else { throw RPCStatus.unavailable }
        return loc
    }

    /// Called when the app comes to the foreground, too.
    func refresh(within limit: Duration) async {
        guard osAllowed("location"), fix == nil else { return }
        locations.requestLocation()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: limit)
            self?.settle()
        }
        await withCheckedContinuation { fix = $0 }
        timer.cancel()
    }

    private func settle() {
        fix?.resume()
        fix = nil
    }

    /// ponytail: CLGeocoder (deprecated in iOS 26 for MapKit's reverse geocoding, still works); cached per 0.1°.
    private func locality(_ loc: CLLocation) async -> String {
        let key = String(format: "%.1f,%.1f", loc.coordinate.latitude, loc.coordinate.longitude)
        if let p = places[key] { return p }
        let place = (try? await withDeadline(.seconds(2)) {
            try await CLGeocoder().reverseGeocodeLocation(loc).first?.locality ?? ""
        }) ?? ""
        if !place.isEmpty { places[key] = place }
        return place
    }
}

extension PhoneServices: CLLocationManagerDelegate {
    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {
        MainActor.assumeIsolated { settle() }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { settle() }
    }
}

/// Redirects only within the URL's host; a redirect elsewhere answers with its 3xx.
private final class SameHost: NSObject, URLSessionTaskDelegate {
    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse,
                    newRequest: URLRequest) async -> URLRequest? {
        let from = task.originalRequest?.url
        guard let to = newRequest.url, to.scheme == "https", to.host?.lowercased() == from?.host?.lowercased()
        else { return nil }
        return newRequest
    }
}

/// WeatherKit's condition as the WMO code Open-Meteo gives (the code table in docs/miniapp-rpc.md).
/// ponytail: nearest code by eye; wind-only conditions read as mostly clear.
func wmo(_ c: WeatherCondition) -> Int {
    switch c {
    case .clear, .hot, .frigid: 0
    case .mostlyClear, .breezy, .windy: 1
    case .partlyCloudy: 2
    case .mostlyCloudy, .cloudy: 3
    case .foggy, .haze, .smoky, .blowingDust: 45
    case .drizzle: 53
    case .freezingDrizzle: 56
    case .sunShowers: 80
    case .rain: 63
    case .heavyRain: 65
    case .freezingRain, .sleet, .wintryMix: 67
    case .flurries, .sunFlurries: 71
    case .snow, .blowingSnow: 73
    case .heavySnow, .blizzard: 75
    case .isolatedThunderstorms, .scatteredThunderstorms, .thunderstorms, .tropicalStorm, .hurricane: 95
    case .hail: 96
    case .strongStorms: 99
    @unknown default: 3
    }
}
