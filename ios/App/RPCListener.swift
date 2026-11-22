import UIKit
import UserNotifications
import WireKit

// Answers the running watch app's service requests (docs/miniapp-rpc.md) for as long as the app lives, foreground
// or woken by BLE in the background. Its own BLELink and K session, next to WatchModel.check's: every K host sees
// every K reply, so INFO and MSG from both go one at a time through KLock. A watchface install stops it (the stock
// session binds the watch) and starts it again after.
// ponytail: retries every 30 s while no watch is up (10 min on stock firmware); no CoreBluetooth state restoration,
// so a kill by the system ends it until the next launch.

/// One K exchange at a time across sessions: a reply carries no request id.
actor KLock {
    static let shared = KLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }

    func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await lock()
        defer { unlock() }
        return try await body()
    }
}

@MainActor final class RPCListener {
    static let shared = RPCListener()
    private var task: Task<Void, Never>?
    /// An install, a face or a firmware update has the watch: off until it starts us again, whatever a check reads.
    private var stopped = false
    private var link: BLELink?
    /// slot → package name, from INFO
    private var apps: [Int: String] = [:]
    /// The stub's release, from the same read: PUSH needs 8, Weather's card 9.
    private var stub: UInt32 = 1

    func start() {
        stopped = false
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                let stock = await listen()
                try? await Task.sleep(for: stock ? .seconds(600) : .seconds(30))
            }
        }
    }

    func stop() {
        stopped = true
        task?.cancel()
        task = nil
        link?.disconnect()
        link = nil
    }

    /// What WatchModel.check read: the apps by slot, and a loader on a watch that had none.
    func update(_ state: LoaderState?) {
        guard let state else { return }
        apps = state.apps.mapValues(\.name)
        stub = state.stub.version
        if task == nil, !stopped { start() }
    }

    /// true: stock firmware, nothing to listen to.
    private func listen() async -> Bool {
        let link = BLELink()
        self.link = link
        var up = true
        link.onDisconnect = { up = false }
        defer {
            link.disconnect()
            if self.link === link { self.link = nil }
        }
        do {
            try await link.connect()
            let (session, state) = try await KLock.shared.run { try await WatchModel.open(link) }
            guard let state else {
                DevLog.shared.log("stock firmware: not listening")
                return true
            }
            apps = state.apps.mapValues(\.name)
            stub = state.stub.version
            // the watch is back (a restart, a reconnect): the Watch tab and Firmware page read it again
            WatchModel.shared.linkCameBack()
            _ = try await KLock.shared.run { try await session.ping() } // registers: the stub sends us EVENTs
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            DevLog.shared.log("listening")
            var card = CardSchedule()
            while up, !Task.isCancelled {
                await runDueJobs(session)
                await refreshWeatherCard(session, &card)
                guard let m = try? await session.recvFrom(timeout: .seconds(5)) else { continue }
                await handle(m.data, slot: Int(m.slot), session)
            }
            DevLog.shared.log("link dropped")
        } catch {
            DevLog.shared.log("link: \(error.localizedDescription)")
        }
        return false
    }

    /// The watch apps' background jobs that are due, while the link is up: in the foreground and in the ~10 s a BLE
    /// wake gives. ponytail: no BGAppRefreshTask; it wakes without the link, and delivering needs it.
    private func runDueJobs(_ session: KSession) async {
        let now = Date.now
        for (package, jobs) in Jobs.shared.all {
            for j in jobs where j.due(now) {
                Jobs.shared.ran(package, j.id, at: now) // first: a failing job waits its interval
                do {
                    let records = try await withDeadline(.seconds(8)) { @MainActor in
                        try await runJob(j, package: package, host: PhoneServices.shared)
                    }
                    await deliver(package, j, records, session, now)
                } catch {
                    DevLog.shared.log("\(package) job \(j.id): \(error)")
                }
            }
        }
    }

    /// Writes a job's records to the app's widget card or start blob (PUSH, stub 8, cmf-watch-sdk docs/widget-push.md).
    private func deliver(_ package: String, _ job: RefreshJob, _ records: [Data], _ session: KSession, _ now: Date) async {
        let line = "\(package) job \(job.id)"
        guard let data = job.pushData(records) else { return DevLog.shared.log("\(line): nothing to push (\(records.count) records)") }
        guard canPush(stub: stub) else { return DevLog.shared.log("\(line): stub \(stub) takes no PUSH (8+)") }
        guard let slot = apps.first(where: { $0.value == package })?.key else { return DevLog.shared.log("\(line): not on the watch") }
        do {
            switch try await KLock.shared.run({ try await push(session, slot: slot, kind: job.target, data: data) }) {
            case .ok: DevLog.shared.log("\(line): pushed to slot \(slot)")
            case .later(let ms):
                // due again once the watch takes a write for this slot
                Jobs.shared.ran(package, job.id, at: now + Double(ms) / 1000 - Double(job.minutes * 60))
            case .refused(let s): DevLog.shared.log("\(line): push refused (\(s))")
            }
        } catch {
            DevLog.shared.log("\(line): push failed: \(error)")
        }
    }

    /// Weather's widget card (docs/miniapp-rpc.md, "Weather's card"): on connect and when the hour changes, in the
    /// foreground and in the wakes this loop gets anyway. No prompt, no location fix, no INFO: that would drop an
    /// install another host has open, so the slot is from the read on connect.
    private func refreshWeatherCard(_ session: KSession, _ card: inout CardSchedule) async {
        let now = Date.now
        guard let hour = Calendar.current.dateInterval(of: .hour, for: now)?.start, card.due(hour: hour, now: now),
              cardSlot() != nil else { return }
        let bg = UIApplication.shared.beginBackgroundTask(withName: "weather-card")
        defer { UIApplication.shared.endBackgroundTask(bg) }
        guard let data = await PhoneServices.shared.weatherCardRecord() else {
            card.settle(nil, card: nil, hour: hour, now: .now)
            return DevLog.shared.log("weather card: no forecast")
        }
        // the fetch took a while: an install may have stopped us, the app or its grant may be gone
        guard !Task.isCancelled, let slot = cardSlot(), !card.unchanged(data, hour: hour) else { return }
        do {
            let result = try await KLock.shared.run {
                try Task.checkCancellation() // an install held the lock
                return try await push(session, slot: slot, kind: .widget, data: data)
            }
            card.settle(result, card: data, hour: hour, now: .now)
            DevLog.shared.log("weather card to slot \(slot): \(result)")
        } catch {
            card.settle(nil, card: data, hour: hour, now: .now)
            DevLog.shared.log("weather card: push failed: \(error)")
        }
    }

    /// Where the card may go now; nil also while the watch installs a firmware.
    private func cardSlot() -> Int? {
        guard !WatchModel.shared.installing else { return nil }
        let phone = PhoneServices.shared
        let granted = phone.grants(weatherPackage)["weather"] == true && phone.osAllowed("weather")
        return weatherCardSlot(stub: stub, apps: apps, granted: granted)
    }

    private func handle(_ message: Data, slot: Int, _ session: KSession) async {
        guard message.starts(with: rpcPrefix) else { return }
        // the ~10 s a BLE wake gives, kept until the reply is out
        let bg = UIApplication.shared.beginBackgroundTask(withName: "rpc")
        defer { UIApplication.shared.endBackgroundTask(bg) }
        if apps[slot] == nil, let state = try? await KLock.shared.run({ try await readLoader(session) }) {
            apps = state.apps.mapValues(\.name)
        }
        // empty: a part of http.request before its last
        guard let out = await answer(message, package: apps[slot], host: PhoneServices.shared), !out.isEmpty else { return }
        // "R1Q id method …" in, "R1A id status index total" out
        let method = message.count > 4 ? DevLog.methods[message[message.startIndex + 4]] ?? "?" : "?"
        let status = out.first.flatMap { $0.count > 4 ? Int($0[$0.startIndex + 4]) : nil }
            .map { $0 < DevLog.statuses.count ? DevLog.statuses[$0] : "\($0)" } ?? "?"
        do {
            try await KLock.shared.run {
                for m in out { try await session.send(m) }
            }
            DevLog.shared.log("\(apps[slot] ?? "slot \(slot)") \(method) → \(status), \(out.count) msg")
        } catch {
            DevLog.shared.log("\(apps[slot] ?? "slot \(slot)") \(method) → \(status), send failed: \(error)")
        }
    }
}

/// Starts the listener at launch (a background launch has no scene) and opens the asking app's page from the ask notification.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        RPCListener.shared.start()
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                               queue: .main) { _ in
            Task { @MainActor in await PhoneServices.shared.refresh(within: .seconds(10)) }
        }
        return true
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        let package = r.notification.request.content.userInfo["package"] as? String
        await MainActor.run { Permissions.shared.open = package }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter,
                                willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound] // a watch app's notify with its sound, also while the companion is open
    }
}
