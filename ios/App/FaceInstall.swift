import Foundation
import os
import WireKit

// A watchface onto the watch the way fmc.tools does it through Bluefy (fmc_frontend ble.ts connect, pair,
// authenticate, uploadWatchface). The stock session can't share the watch with Nothing X, so the user closes
// Nothing X first, and may have to add the watch to it again afterwards (fmc issue #27). The UI says so before
// every install (FMC-8, item 2: Egor's call, 2026-11-17).

enum FaceInstallError: LocalizedError {
    case refused(FaceRefusal), full, noFile

    var errorDescription: String? {
        switch self {
        case .refused(.aodWithoutPreview):
            String(localized: "The always-on screen of this face has no thumbnail. Faces like this made the screen flash on a watch. Open it in the editor on fmc.tools and install it from there.")
        case .refused(.imageTooBig(let w, let h)):
            String(localized: "An image of this face is \(w)×\(h) px. Over \(maxImageSide) px can make the watch restart in a loop.")
        case .refused(.screenOverBudget(let aod, let bytes)):
            aod ? String(localized: "The always-on screen of this face needs \(mb(bytes)) MB of the watch's memory, more than the \(mb(screenBudget)) MB a Watch 3 Pro holds: the watch would restart in a loop. Use fewer or smaller full-screen images in the editor on fmc.tools.")
                : String(localized: "The main screen of this face needs \(mb(bytes)) MB of the watch's memory, more than the \(mb(screenBudget)) MB a Watch 3 Pro holds: the watch would restart in a loop. Use fewer or smaller full-screen images in the editor on fmc.tools.")
        case .refused(.unmeasurable):
            String(localized: "The app can't measure how much memory this face needs, and too much makes a Watch 3 Pro restart in a loop. Nothing was sent to the watch.")
        case .refused: String(localized: "This file is not a watch face.")
        case .full: String(localized: "The watch is full. Delete a face on the watch (long press the face, swipe one up) and try again.")
        case .noFile: String(localized: "This watch face has no file.")
        }
    }

    /// The site's `toFixed(1)` of megabytes, in the user's locale.
    private func mb(_ bytes: Int) -> String { (Double(bytes) / 1e6).formatted(.number.precision(.fractionLength(1))) }
}

/// A dial on the watch. `index`: its place in the watch's own carousel, the only handle on a dial nobody named.
struct DialSlot: Identifiable {
    let id: UInt32, index: Int
    /// The watch only reports ids: faces this app installed keep their name, stock ones are named from fmc.tools'
    /// stock-dials.json, Nothing X gallery ones have nothing to go on.
    var label: String {
        UserDefaults.standard.string(forKey: "dial-name-\(id)") ?? Self.stock[id] ?? String(localized: "Face \(index + 1)")
    }

    /// The preview of a face this app installed (a draft that is in no list now, or a face since deleted).
    var savedPreview: URL? { UserDefaults.standard.url(forKey: "dial-preview-\(id)") }

    /// An FMC catalog face, from this app or from fmc.tools: its dial id is `dialId(record id)`.
    @MainActor func face(in catalog: Catalog) -> DialFace? { catalog.dials[id] }

    /// fmc_frontend modules/device/lib/stock-dials.json: id → name of the factory and Nothing gallery faces.
    static let stock: [UInt32: String] = {
        struct Entry: Decodable { var name: String }
        guard let url = Bundle.main.url(forResource: "stock-dials", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: map.compactMap { k, v in UInt32(k).map { ($0, v.name) } })
    }()
}

/// ble.ts WF_CAPACITY
// ponytail: the watch takes 6; a055's 4th byte says 7 (a built-in face?), so it is ignored
let capacity = 6

enum FaceInstall {
    /// The file and the gate's verdict: nothing goes to the watch before the user has seen it.
    static func fetch(_ face: Watchface) async throws -> (Data, FaceVerdict) {
        guard let url = face.binURL else { throw FaceInstallError.noFile }
        let (bin, _) = try await URLSession.shared.data(from: url)
        let verdict = checkFace(bin)
        if case .refuse(let why) = verdict { throw FaceInstallError.refused(why) }
        return (bin, verdict)
    }

    /// `fitForWatch` for the watch on the line, then the gate again with its model (ble.model.ts flashFx): a Watch 3
    /// Pro gets its heaviest images as ETC2, or a refusal for a screen that still doesn't fit. Seconds on a heavy
    /// face: off the main thread. Returns the file to send and how many images went ETC2.
    static func fit(_ bin: Data, watchName: String?) async throws -> (Data, Int) {
        let w3 = isWatch3Pro(watchName)
        return try await Task.detached(priority: .userInitiated) {
            let (out, compressed) = try fitForWatch(bin, watch3Pro: w3)
            if case .refuse(let why) = checkFace(out, watch3Pro: w3) { throw FaceInstallError.refused(why) }
            return (out, compressed)
        }.value
    }

    /// Connects and opens a stock session (a new bind only when the saved key is refused, and `bind` allows one:
    /// it pops up on the watch), then `body`. `before` sees the link before anything is sent: it can still refuse.
    @MainActor static func session<T>(bind: Bool = true, before: @MainActor (BLELink) async throws -> Void = { _ in },
                                      _ body: (StockSession, String) async throws -> T) async throws -> T {
        // the stock session binds the watch: the RPC listener waits it out
        RPCListener.shared.stop()
        defer { RPCListener.shared.start() }
        let link = BLELink()
        defer { link.disconnect() }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(30))
            link.abort()
        }
        try await link.connect(scan: true)
        watchdog.cancel()
        try await before(link)
        let watch = link.watchID?.uuidString ?? ""
        var secret = Keychain.get("k-\(watch)")
        if secret == nil {
            secret = try await KSession.open(link: link, register: false).secretHex
            Keychain.set("k-\(watch)", secret)
        }
        let session = StockSession(link: link)
        let saved = Keychain.get("stock-\(watch)").flatMap(Data.init(hex:))
        do {
            guard let saved else { throw UploadError.authFailed }
            try await session.authenticate(k1: saved)
        } catch UploadError.authFailed where bind, WireError.timeout where bind {
            // no key yet, or the watch was bound again since (Nothing X, a reset): bind, as the site does
            let k1 = try await session.pair(secret: Data(hex: secret ?? "") ?? Data())
            Keychain.set("stock-\(watch)", k1.map { String(format: "%02x", $0) }.joined())
        }
        return try await body(session, watch)
    }

    /// What the watch reported in a055, plus the dials this app put there that the list leaves out.
    private static func dials(_ session: StockSession, _ watch: String) async
        -> (mine: [UInt32], installed: [UInt32], counted: (count: Int, capacity: Int)?, header: String) {
        let mine = UserDefaults.standard.array(forKey: "dials-\(watch)") as? [UInt32] ?? []
        let reported = await session.installedDials() ?? []
        let installed = reported + mine.filter { !reported.contains($0) }
        // the header counts side-loaded dials too; the hardcoded capacity and the id list are the fallback
        let counted = await session.dialCount
        let header = (await session.dialHeader ?? Data()).map { String(format: "%02x", $0) }.joined(separator: " ")
        Logger(subsystem: "tools.fmc.companion", category: "dials")
            .notice("a055 header \(header, privacy: .public), \(reported.count) listed, \(installed.count) known")
        return (mine, installed, counted, header)
    }

    /// What the Watch tab shows.
    private static func remember(_ onWatch: [UInt32], count: Int?, capacity: Int, header: String) {
        UserDefaults.standard.set(onWatch, forKey: "faces-on-watch")
        UserDefaults.standard.set(Date(), forKey: "faces-on-watch-date")
        UserDefaults.standard.set(count.map { [$0, capacity] }, forKey: "faces-on-watch-count")
        UserDefaults.standard.set(header, forKey: "faces-on-watch-header")
    }

    /// Reads the dials off the watch for the Watch tab. `bind`: when the saved key is missing or refused, bind
    /// (a popup on the watch, and Nothing X loses the watch, like an install); else that throws authFailed.
    @MainActor static func read(bind: Bool) async throws {
        try await session(bind: bind) { session, watch in
            let d = await dials(session, watch)
            remember(d.installed, count: d.counted?.count, capacity: capacity, header: d.header)
            UserDefaults.standard.set(await session.listed, forKey: "faces-on-watch-all")
        }
    }

    /// The face on screen, from the last read: a055 byte 1 indexes the full list.
    static var activeDial: UInt32? {
        let all = UserDefaults.standard.array(forKey: "faces-on-watch-all") as? [UInt32] ?? []
        let header = UserDefaults.standard.string(forKey: "faces-on-watch-header") ?? ""
        guard let i = header.split(separator: " ").dropFirst().first.flatMap({ Int($0, radix: 16) }), all.indices.contains(i)
        else { return nil }
        return all[i]
    }

    /// Shows `id` on the watch.
    @MainActor static func activate(_ id: UInt32) async throws {
        try await edit { all, _ in all.firstIndex(of: id).map { (all, $0) } }
    }

    /// Takes `id` off the watch; the face on screen stays, or the first one if it was that. A downloaded face's
    /// file goes at the watch's next boot or upload; built-in faces stay on it, unlisted.
    @MainActor static func delete(_ id: UInt32) async throws {
        try await edit { all, active in
            let kept = all.filter { $0 != id }
            return kept.count == all.count ? nil : (kept, active.flatMap { kept.firstIndex(of: all[$0]) } ?? 0)
        }
    }

    /// Reads the full list, sends `change(list, active index)` (nil: nothing to do), saves what the watch reports.
    /// A user's own action, like an install: a refused key binds again (the popup on the watch).
    @MainActor private static func edit(_ change: ([UInt32], Int?) -> ([UInt32], Int)?) async throws {
        try await session { session, watch in
            _ = await session.installedDials()
            let all = await session.listed ?? []
            let active = await session.dialHeader.flatMap { $0.count >= 2 ? Int($0[$0.startIndex + 1]) : nil }
            if let (ids, i) = change(all, active) {
                try await session.setDials(ids, active: i)
                // a face taken off is no longer this app's either
                let listed = await session.listed ?? []
                let mine = UserDefaults.standard.array(forKey: "dials-\(watch)") as? [UInt32] ?? []
                UserDefaults.standard.set(mine.filter { listed.contains($0) }, forKey: "dials-\(watch)")
            }
            let d = await dials(session, watch)
            remember(d.installed, count: d.counted?.count, capacity: capacity, header: d.header)
            UserDefaults.standard.set(await session.listed, forKey: "faces-on-watch-all")
        }
    }

    /// The dials to pick from before connecting: the watch was full when last read and this face isn't on it.
    /// nil: room, or never read; the install finds out on the watch.
    static func knownFull(seed: String) -> [DialSlot]? {
        let ids = UserDefaults.standard.array(forKey: "faces-on-watch") as? [UInt32] ?? []
        let count = UserDefaults.standard.array(forKey: "faces-on-watch-count") as? [Int]
        let full = (count?.first ?? ids.count) >= capacity
        guard full, !ids.isEmpty, !ids.contains(dialId(seed)) else { return nil }
        return ids.enumerated().map { DialSlot(id: $1, index: $0) }
    }

    /// Uploads `bin`, fitted to the watch first (`fit`). `slot`: the dial to replace, picked before connecting
    /// (`knownFull`); `pick`: the watch is full and nothing was picked yet, which dial goes; nil cancels the install.
    /// Returns how many images were compressed to fit the watch's memory.
    @discardableResult
    @MainActor static func install(_ file: Data, seed: String, name: String, slot preset: UInt32? = nil,
                                   pick: @MainActor ([DialSlot]) async -> UInt32?,
                                   progress: @escaping @Sendable (Int) -> Void) async throws -> Int {
        var bin = file, compressed = 0
        try await session(before: { link in (bin, compressed) = try await fit(file, watchName: link.watchName) }) { session, watch in
            let (mine, installed, counted, header) = await dials(session, watch)
            let cap = capacity
            let full = (counted?.count ?? installed.count) >= capacity
            // which dial to replace (ble.ts NoFreeSlotError, slot-dialog.svelte)
            func ask() async throws -> UInt32 {
                guard let picked = await pick(installed.enumerated().map { DialSlot(id: $1, index: $0) })
                else { throw CancellationError() }
                return picked
            }
            // full and not a re-install of this face: ask before sending anything
            // a pick made from a stale list stands only while that dial is still there
            var slot = preset.flatMap { installed.contains($0) ? $0 : nil }
            if slot == nil, full, !installed.contains(dialId(seed)) { slot = try await ask() }
            let id: UInt32
            do {
                do {
                    id = try await installFace(session, bin, seed: seed, installed: installed, capacity: cap,
                                               slot: slot, progress: progress)
                } catch UploadError.noFreeSlot where slot == nil && !installed.isEmpty {
                    // the count said there was room and the watch said no: the header reading is wrong, or it is missing
                    slot = try await ask()
                    id = try await installFace(session, bin, seed: seed, installed: installed, capacity: cap,
                                               slot: slot, progress: progress)
                }
            } catch UploadError.noFreeSlot {
                throw FaceInstallError.full
            }
            UserDefaults.standard.set(name, forKey: "dial-name-\(id)")
            let now = mine.filter { $0 != slot } + (mine.contains(id) ? [] : [id])
            UserDefaults.standard.set(now, forKey: "dials-\(watch)")
            let onWatch = slot.map { s in installed.map { $0 == s ? id : $0 } }
                ?? (installed.contains(id) ? installed : installed + [id])
            remember(onWatch, count: counted.map { slot != nil || installed.contains(id) ? $0.count : $0.count + 1 },
                     capacity: cap, header: header)
        }
        return compressed
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var d = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            d.append(b)
            i = j
        }
        self = d
    }
}
