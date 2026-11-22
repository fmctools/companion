import SwiftUI
import UIKit
import WireKit

// Firmware: what the watch runs (the patched stub and the App Loader) against what fmc.tools publishes (`firmwares`,
// kinds `patched` and `loader`), checked right after each connect. The App Loader updates from here over K; the
// patched firmware goes over the stock OTA (WireKit Ota.swift, as fmc.tools' flashFirmware).

@MainActor @Observable final class FirmwareModel {
    static let shared = FirmwareModel()

    struct Release {
        let name: String
        let version: String
        /// STUB_VERSION for the patched firmware
        let stub: Int
        let file: URL
    }

    struct Check {
        var firmware: Release?
        var loader: Release?
        /// the store's loader package: its CRC tells whether the watch has it, and it is what Update installs
        var loaderPackage: Data?
        var loaderHeader: PackageHeader?
    }

    private(set) var check: Check?
    private(set) var checking = false
    private(set) var error: String?
    private(set) var progress: Double?
    /// The firmware update under way: what it is doing and, once the watch reports a percent, how far.
    private(set) var flash: Flash?
    private(set) var flashed = false

    struct Flash {
        var step: LocalizedStringKey
        var percent: Int?
        var started = Date()

        /// From the watch's own percent: it skips what it has, so the rate is what counts.
        var left: Duration? {
            guard let percent, percent >= 2, percent < 100 else { return nil }
            let elapsed = Date().timeIntervalSince(started)
            return .seconds(elapsed / Double(percent) * Double(100 - percent))
        }
    }

    /// The store's loader differs from the one on the watch (or the watch has none).
    func loaderUpdate(_ state: LoaderState?) -> Bool {
        // the store's loader with the phone's app order in it: that is what Update installs
        guard let state, let pkg = check?.loaderPackage, let want = parseHeader(AppOrder.shared.patched(pkg)) else { return false }
        return state.loader?.crc != want.crc
    }

    /// The store's patched firmware has a newer stub than the watch.
    func firmwareUpdate(_ state: LoaderState?) -> Bool {
        guard let state, let fw = check?.firmware else { return false }
        return fw.stub > Int(state.stub.version)
    }

    func updates(_ state: LoaderState?) -> Int { (loaderUpdate(state) ? 1 : 0) + (firmwareUpdate(state) ? 1 : 0) }

    /// `account`: a moderator's sign-in also lists the drafts, as fmc.tools does (fmc_pocketbase's list rule decides).
    func refresh(_ account: Account? = nil) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            struct Page: Decodable { var items: [Record] }
            struct Record: Decodable { var id, collectionId, name, kind, version, image: String; var stub: Int; var published: Bool }
            var url = Account.base.appending(path: "api/collections/firmwares/records")
            url.append(queryItems: [
                .init(name: "filter", value: "device = 'watch_pro_2' && (kind = 'patched' || kind = 'loader')"),
                // newest first by creation: a download bumps the live record's `updated`, which hid a moderator's draft
                .init(name: "sort", value: "-created"),
                .init(name: "fields", value: "id,collectionId,name,kind,version,image,stub,published"),
            ])
            var r = URLRequest(url: url)
            account?.authorize(&r)
            let (data, _) = try await URLSession.shared.data(for: r)
            let records = try JSONDecoder().decode(Page.self, from: data).items
            func release(_ kind: String) -> Release? {
                records.first { $0.kind == kind }.map {
                    Release(name: $0.published || $0.name.localizedCaseInsensitiveContains("draft") ? $0.name : "\($0.name) (draft)", version: $0.version, stub: $0.stub,
                            file: Account.base.appending(path: "api/files/\($0.collectionId)/\($0.id)/\($0.image)"))
                }
            }
            var c = Check(firmware: release("patched"), loader: release("loader"))
            if let loader = c.loader {
                let (pkg, _) = try await URLSession.shared.data(from: loader.file)
                c.loaderPackage = pkg
                c.loaderHeader = parseHeader(pkg)
            }
            check = c
            error = nil
        } catch {
            self.error = String(localized: "Couldn't check for updates: \(error.localizedDescription)")
        }
    }

    /// The store's patched firmware over the stock OTA. The image is checked before connecting and the watch's
    /// model before the stock session opens (ota-image.ts checkOtaTarget): nothing goes out for a refused one.
    func flashFirmware() async {
        guard let file = check?.firmware?.file, flash == nil else { return }
        flash = Flash(step: "Downloading the firmware…")
        flashed = false
        error = nil
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            flash = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        do {
            let (image, _) = try await URLSession.shared.data(from: file)
            // 57 MB of CRCs: off the main actor
            let info = try await Task.detached { try inspectOtaImage(image) }.value
            flash?.step = "Connecting to the watch…"
            try await FaceInstall.session(before: { link in try checkOtaTarget(info, watchName: link.watchName) }) {
                session, _ in
                await MainActor.run { self.flash = Flash(step: "Sending the firmware…") }
                try await session.flashFirmware(image) { p in
                    Task { @MainActor in
                        if self.flash?.percent == nil { self.flash?.started = Date() }
                        self.flash?.percent = p
                    }
                }
            }
            DevLog.shared.log("Firmware sent: \(check?.firmware?.version ?? "?")")
            Analytics.track("firmware_installed")
            flashed = true
        } catch {
            self.error = String(localized: "Couldn't update the firmware: \(error.localizedDescription)")
        }
    }

    /// The watch answered with the new firmware.
    func landed() {
        flashed = false
        DevLog.shared.log("Firmware installed: the watch answered with it")
    }

    /// One package over K (the loader or an app, into its own slot), with the RPC listener off meanwhile.
    static func install(_ pkg: Data, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await k { _ = try await WireKit.install($0, package: pkg, progress: progress) }
    }

    static func remove(slot: Int) async throws {
        try await k { try await WireKit.remove($0, slot: slot) }
    }

    /// One K session of its own; the services' listener holds K, so it is off meanwhile.
    private static func k(_ body: @escaping @Sendable (any Requester) async throws -> Void) async throws {
        RPCListener.shared.stop()
        defer { RPCListener.shared.resume() }
        let link = BLELink()
        defer { link.disconnect() }
        try await link.connect()
        try await KLock.shared.run {
            let (session, _) = try await WatchModel.open(link)
            try await body(session)
        }
    }

    /// Installs the store's App Loader over K, then reads the watch again.
    func updateLoader(_ watch: WatchModel) async {
        guard let store = check?.loaderPackage else { return }
        let pkg = AppOrder.shared.patched(store)
        progress = 0
        defer { progress = nil }
        do {
            try await Self.install(pkg) { p in Task { @MainActor in self.progress = p } }
            DevLog.shared.log("App Loader installed (crc \(String(format: "%08x", parseHeader(pkg)?.crc ?? 0)))")
            Analytics.track("loader_installed")
            error = nil
            await watch.check()
        } catch InstallError.busy {
            // stub 6 takes the install behind a page and reloads it there (cmf-watch-sdk docs/abi-1.4.md): busy is
            // then only what is on screen
            error = (watch.loader?.stub.version ?? 0) >= 6
                ? String(localized: "An app or the Apps menu is open on the watch. Go back to the watch face, then try again.")
                : String(localized: "The App Loader is running on the watch. Close the Apps menu and any running app, and remove the watch app pages and widgets you added, then try again. Patched firmware with stub 6 or later doesn't need this.")
        } catch {
            self.error = String(localized: "Couldn't update the App Loader: \(error.localizedDescription)")
        }
    }
}

struct FirmwareView: View {
    @Environment(WatchModel.self) private var watch
    @Environment(Account.self) private var account
    private var model = FirmwareModel.shared
    @State private var confirmFlash = false

    var body: some View {
        let state = watch.loader
        List {
            Section {
                LabeledContent("Firmware") {
                    if watch.installing { Text("Installing…") }
                    else if let state { Text("Patched · stub \(state.stub.version)") }
                    else if case .checked = watch.phase { Text("Stock") }
                    else { Text("—") }
                }
                LabeledContent("App Loader") {
                    if let l = state?.loader { Text(String(format: "%08x", l.crc)).monospaced() }
                    else if state != nil { Text("Not installed") }
                    else { Text("—") }
                }
            } header: {
                Text("On the watch")
            } footer: {
                if !connected { Text("Connect on the Watch tab to read the watch.") }
            }

            Section {
                if let fw = model.check?.firmware {
                    VStack(spacing: 10) {
                        LabeledContent {
                            if let f = model.flash {
                                Text(f.percent.map { "\($0)%" } ?? "").monospacedDigit().foregroundStyle(.secondary)
                            } else if model.firmwareUpdate(state) || (state == nil && connected) {
                                Button(state == nil ? "Install" : "Update") { confirmFlash = true }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.progress != nil)
                            } else {
                                Text(state == nil ? "" : "Up to date").foregroundStyle(.secondary)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(fw.name)
                                Text("\(fw.version) · stub \(fw.stub)").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        // the whole row's width: a 57 MB update is long enough to watch
                        if let f = model.flash {
                            if let p = f.percent { ProgressView(value: Double(p), total: 100) } else { ProgressView().frame(maxWidth: .infinity) }
                        }
                    }
                }
                if let loader = model.check?.loader {
                    LabeledContent {
                        if model.loaderUpdate(state), model.progress == nil {
                            Button(state?.loader == nil ? "Install" : "Update") {
                                Task { await model.updateLoader(watch) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.check?.loaderPackage == nil)
                        } else if let p = model.progress {
                            ProgressView(value: p).frame(width: 80)
                        } else {
                            Text(state == nil ? "" : "Up to date").foregroundStyle(.secondary)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(loader.name)
                            Text(loader.version).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Button {
                    Task { await model.refresh(account) }
                } label: {
                    HStack {
                        Text("Check for updates")
                        Spacer()
                        if model.checking { ProgressView() }
                    }
                }
                .disabled(model.checking)
            } header: {
                Text("fmc.tools")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let f = model.flash {
                        flashStatus(f)
                    } else if watch.installing {
                        Text("The watch is installing the update and restarts by itself, which takes a few minutes. The app reads it every 20 seconds until it's back.")
                    } else if model.flashed {
                        Text("Firmware sent, but the watch hasn't answered with it in 10 minutes. Check the watch, then connect again on the Watch tab.")
                    } else if model.firmwareUpdate(state) || (state == nil && connected) {
                        Text("The firmware is about 57 MB. Before installing: charge the watch, keep the phone next to it, and close Nothing X.")
                    }
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("Firmware")
        .alert("Close Nothing X first", isPresented: $confirmFlash) {
            // not tied to this screen: the wait goes on if the user leaves it
            Button("Install") {
                Task {
                    let target = UInt32(model.check?.firmware?.stub ?? 0)
                    await model.flashFirmware()
                    if model.flashed, await watch.awaitRestart(stub: target) { model.landed() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The watch talks to one app at a time. Close Nothing X (swipe it away in the app switcher), then install.\n\nThe watch should be charged and the phone next to it. Keep this screen open until the update is sent; the watch then installs it and restarts.\n\nAfterwards Nothing X may not see the watch. Then forget the watch in Bluetooth settings and add it again in Nothing X.")
        }
        .task { if model.check == nil { await model.refresh(account) } }
    }

    private func flashStatus(_ f: FirmwareModel.Flash) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let p = f.percent {
                if let left = f.left {
                    Text("Sending the firmware: \(p)%, about \(left.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) left. Keep the phone next to the watch and this screen open.")
                } else {
                    Text("Sending the firmware: \(p)%. Keep the phone next to the watch and this screen open.")
                }
            } else {
                Text(f.step)
            }
        }
    }

    private var connected: Bool { if case .checked = watch.phase { true } else { false } }
}
