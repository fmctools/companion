import Foundation
import Testing
@testable import WireKit

/// The stub's install commands, scripted: `used` slots answer INFO with a header, writes are recorded.
final class FakeInstaller: Requester, @unchecked Sendable {
    var used: [Int: Data] = [:]
    var calls: [(UInt16, Data)] = []
    var beginStatus: Status = .ok
    var written = 0
    /// INFO 0xFE: a stub 1 answers it as a bad slot.
    var stub = Data([1])

    func call(_ c2: UInt16, _ payload: Data, timeout: Duration) async throws -> Data {
        calls.append((c2, payload))
        switch c2 {
        case Cmd.info:
            if payload.first == stubSlot { return stub }
            return Data([0]) + (used[Int(payload[payload.startIndex])] ?? Data())
        case Cmd.begin: return Data([beginStatus.rawValue])
        case Cmd.data:
            written = Int(payload.le(UInt32.self, at: 0)) + payload.count - 4
            var r = Data([0])
            r.le(UInt32(written))
            return r
        default: return Data([0])
        }
    }
}

let pkg = v.package
let header = hex(pkg.info_reply_hex).dropFirst()

@Test func headerMatchesPython() {
    // the image CRC: crc32 of what follows the header, as package.pack writes it
    let want = PackageHeader(kind: pkg.kind, name: pkg.name, version: pkg.version,
                             crc: crc32(Data(hex(pkg.hex).dropFirst(64))))
    #expect(parseHeader(Data(header)) == want)
    #expect(parseHeader(hex(pkg.hex)) == want)
    #expect(parseHeader(Data(count: 64)) == nil)
}

@Test func payloadsMatchPython() async throws {
    let f = FakeInstaller()
    f.used = [0: Data(header), 1: Data(header), 2: Data(header)]
    f.used[0]![8] = UInt8(ascii: "x") // another app in slot 0
    f.used[1]![8] = UInt8(ascii: "y")
    f.used[2]![8] = UInt8(ascii: "z")
    nonisolated(unsafe) var seen: [Double] = []
    let slot = try await install(f, package: hex(pkg.hex)) { seen.append($0) }
    #expect(slot == 3)
    let writes = f.calls.filter { $0.0 != Cmd.info }
    #expect(writes.map(\.1) == [hex(pkg.begin_hex)] + pkg.data_hex.map(hex) + [hex(pkg.end_hex)])
    #expect(seen.last == 1)
}

@Test func picksSameNameSlot() async throws {
    let f = FakeInstaller()
    f.used = [5: Data(header)]
    #expect(try await install(f, package: hex(pkg.hex)) { _ in } == 5)
}

@Test func installBusy() async throws {
    let f = FakeInstaller()
    f.beginStatus = .busy
    await #expect(throws: InstallError.busy) { try await install(f, package: hex(pkg.hex)) { _ in } }
    #expect(!f.calls.contains { $0.0 == Cmd.data }, "nothing half-written")
}

@Test func noFreeSlot() async throws {
    let f = FakeInstaller()
    for i in 0..<8 {
        var h = Data(header)
        h[8] = UInt8(ascii: "a") + UInt8(i)
        f.used[i] = h
    }
    await #expect(throws: InstallError.noFreeSlot(slots: 8)) { try await install(f, package: hex(pkg.hex)) { _ in } }
    #expect(!f.calls.contains { $0.0 == Cmd.info && $0.1.first == 8 }, "stub 1: slots 0…7 only")
}

@Test func stubEightHasSixteenSlots() async throws {
    #expect([1, 6, 7, 8, 9].map { appSlots(stub: $0) } == [8, 8, 8, 16, 16])
    let f = FakeInstaller()
    f.stub = Data([0, 8, 0, 0, 0, 4])
    for i in 0..<8 {
        var h = Data(header)
        h[8] = UInt8(ascii: "a") + UInt8(i)
        f.used[i] = h
    }
    #expect(try await install(f, package: hex(pkg.hex)) { _ in } == 8, "the first free slot past 7")
    for i in 8..<16 {
        var h = Data(header)
        h[8] = UInt8(ascii: "a") + UInt8(i)
        f.used[i] = h
    }
    await #expect(throws: InstallError.noFreeSlot(slots: 16)) { try await install(f, package: hex(pkg.hex)) { _ in } }
}

/// order-vectors.json: tools/order-vectors.py, from the SDK's own package.set_order.
private struct OrderVectors: Decodable {
    struct Ok: Decodable { let names: [String]; let hex: String }
    struct Bad: Decodable { let loader: String; let names: [String]; let note: String }
    let loader: String; let ok: [Ok]; let bad: [Bad]
}

@Test func orderMatchesSDK() throws {
    let url = try #require(Bundle.module.url(forResource: "order-vectors", withExtension: "json"))
    let o = try JSONDecoder().decode(OrderVectors.self, from: Data(contentsOf: url))
    for c in o.ok {
        let got = try setOrder(hex(o.loader), names: c.names)
        #expect(got == hex(c.hex), "\(c.names)")
        #expect(parseHeader(got)?.crc == parseHeader(hex(c.hex))?.crc)
    }
    for c in o.bad {
        #expect(throws: (any Error).self, "\(c.note)") { try setOrder(hex(c.loader), names: c.names) }
    }
}

/// push-vectors.json: tools/push-vectors.py, the records from the SDK's own widget_record and columns_record.
struct PushVectors: Decodable {
    struct W: Decodable { let title: String; let value: String; let hex: String }
    struct P: Decodable { let slot: Int; let kind: Int; let data: String; let hex: String }
    struct R: Decodable { let hex: String; let ok: Bool?; let later_ms: UInt32?; let refused: UInt8? }
    struct B: Decodable { let records: [String]; let blob: String? }
    struct H: Decodable { let records: [String]; let title: String?; let value: String?; let none: Bool? }
    struct C: Decodable { let caption: String; let icon: Int?; let value: String }
    struct Columns: Decodable { let note: String; let columns: [C]; let hex: String }
    struct Damage: Decodable { let note: String; let flip: Int?; let keep: Int? }
    struct Trailer: Decodable { let stub: UInt32; let package: String; let plain: String; let damaged: [Damage] }
    let trailer: Trailer
    struct Card: Decodable {
        let note: String; let at: String; let start: String
        let now: [Double]?; let hours: [[Double]]; let hex: String?
    }
    let weather_icons: [[Int]]; let weather_cards: [Card]
    let command: Int; let widget: [W]; let payload: [P]; let replies: [R]; let blob: [B]; let http_widget: [H]
    let columns_stub: UInt32; let columns: [Columns]; let columns_bad: [[C]]

    static func load() throws -> PushVectors {
        let url = try #require(Bundle.module.url(forResource: "push-vectors", withExtension: "json"))
        return try JSONDecoder().decode(PushVectors.self, from: Data(contentsOf: url))
    }
}

@Test func pushMatchesSDK() throws {
    let p = try PushVectors.load()
    #expect(p.command == Int(Cmd.push))
    for w in p.widget { #expect(widgetRecord(title: w.title, value: w.value) == hex(w.hex), "\(w.title)") }
    for c in p.payload { #expect(pushPayload(slot: c.slot, kind: PushKind(rawValue: c.kind)!, data: hex(c.data)) == hex(c.hex)) }
    for r in p.replies {
        let want: PushResult = r.ok == true ? .ok : r.later_ms.map { .later(ms: $0) } ?? .refused(r.refused!)
        #expect(parsePushReply(hex(r.hex)) == want, "\(r.hex)")
    }
    for b in p.blob { #expect(jobBlob(b.records.map(hex)) == b.blob.map(hex)) }
    for h in p.http_widget {
        #expect(jobWidget(h.records.map(hex)) == (h.none == true ? nil : widgetRecord(title: h.title!, value: h.value!)))
    }
    #expect([6, 7, 8].map { canPush(stub: $0) } == [false, false, true])
}

@Test func columnsMatchSDK() throws {
    let p = try PushVectors.load()
    func columns(_ c: [PushVectors.C]) -> [WidgetColumn] {
        c.map { WidgetColumn(caption: $0.caption, icon: $0.icon, value: $0.value) }
    }
    for c in p.columns { #expect(columnsRecord(columns(c.columns)) == hex(c.hex), "\(c.note)") }
    for c in p.columns_bad { #expect(columnsRecord(columns(c)) == nil) }
    #expect(!canPushColumns(stub: p.columns_stub - 1) && canPushColumns(stub: p.columns_stub))
    #expect(p.columns_stub == 10 && !canPushColumns(stub: 9), "stub 9, the face guard, refuses v2")
}

/// What the watch receives for `file` from a phone that sees `stub`: the DATA payloads joined, and BEGIN's size and CRC
/// must be of those bytes.
private func sent(_ file: Data, stub: UInt32) async throws -> Data {
    let f = FakeInstaller()
    if stub > 1 {
        f.stub = Data([0])
        f.stub.le(stub)
        f.stub.append(4)
    }
    nonisolated(unsafe) var seen: [Double] = []
    _ = try await install(f, package: file) { seen.append($0) }
    let got = f.calls.filter { $0.0 == Cmd.data }.reduce(into: Data()) { $0 += $1.1.dropFirst(4) }
    let begin = try #require(f.calls.first { $0.0 == Cmd.begin }?.1)
    #expect(begin.le(UInt32.self, at: 1) == UInt32(got.count) && begin.le(UInt32.self, at: 5) == crc32(got))
    #expect(seen.last == 1)
    return got
}

@Test func widgetIconTrailer() async throws {
    let t = try PushVectors.load().trailer
    let packed = hex(t.package), plain = hex(t.plain)
    #expect(parseHeader(packed) == parseHeader(plain) && parseHeader(packed)?.name == "weather")
    #expect(t.stub == 10, "stub 9, the face guard, refuses extra bytes at END")
    for stub: UInt32 in [1, 7, 9, t.stub - 1] {
        #expect(try await sent(packed, stub: stub) == plain, "stub \(stub): the package without icons, byte for byte")
    }
    for stub in [t.stub, t.stub + 1] { #expect(try await sent(packed, stub: stub) == packed, "stub \(stub): whole") }
    for stub in [1, t.stub] { #expect(try await sent(plain, stub: stub) == plain, "no trailer: as it is") }
    for d in t.damaged {
        var bad = [UInt8](packed.prefix(d.keep ?? packed.count))
        if let i = d.flip { bad[i] ^= 0xFF }
        #expect(try await sent(Data(bad), stub: t.stub - 1) == plain, "\(d.note): an older stub never sees it")
        #expect(try await sent(Data(bad), stub: t.stub) == Data(bad), "\(d.note): stub 10 checks it itself")
    }
    var huge = [UInt8](packed)
    huge.replaceSubrange(44..<48, with: [0xFF, 0xFF, 0xFF, 0xFF])
    #expect(stripTrailer(Data(huge)) == Data(huge), "a size past the file is left for the stub to refuse")
}
