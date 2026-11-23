import Foundation

// Installing an app package from the phone over K (src/wp2apps/install.py): INFO, BEGIN, DATA…, END.

public let loaderSlot = 0xFF

/// App slots on the watch, 0…n−1: 8 before stub 8, 16 from stub 8 (cmf-watch-sdk docs/app-order.md, "The table"; stub 7 on
/// cmf-watch-sdk main is another change).
public func appSlots(stub: UInt32) -> Int { stub >= 8 ? 16 : 8 }

/// The stub's release from INFO on 0xFE; 1 when the reply doesn't say.
public func stubVersion(_ s: Requester) async throws -> UInt32 {
    parseStubReply(try await s.call(Cmd.info, Data([stubSlot])))?.version ?? 1
}
let headerSize = 64, dataMax = 128

/// What install needs from a session: one request, the plain reply. KSession in the app, a fake in the tests.
public protocol Requester: Sendable {
    func call(_ c2: UInt16, _ payload: Data, timeout: Duration) async throws -> Data
}

extension Requester {
    func call(_ c2: UInt16, _ payload: Data) async throws -> Data { try await call(c2, payload, timeout: .seconds(6)) }
}

extension KSession: Requester {}

public struct PackageHeader: Equatable, Sendable {
    public var kind: Int
    public var name: String
    public var version: UInt32
    /// CRC-32 of the image: tells two builds with the same version apart (the loader's version stays 1).
    public var crc: UInt32

    public init(kind: Int, name: String, version: UInt32, crc: UInt32 = 0) {
        (self.kind, self.name, self.version, self.crc) = (kind, name, version, crc)
    }
}

public enum InstallError: Error, Equatable {
    case busy, notAPackage
    /// Every one of the watch's `slots` app slots holds another app.
    case noFreeSlot(slots: Int)
    case refused(UInt8)
}

/// The first stub that takes a package's widget icon trailer ("WP2W", cmf-watch-sdk docs/app-icons.md).
let trailerStub: UInt32 = 10

/// The package without its widget icon trailer, the same bytes as one packed without icons: body_crc doesn't cover
/// the trailer (package.strip_trailer). An older stub refuses any byte past what the header says.
func stripTrailer(_ p: Data) -> Data {
    guard p.count >= headerSize else { return p }
    let end = UInt64(headerSize) + UInt64(p.le(UInt32.self, at: 36)) + 4 * UInt64(p.le(UInt32.self, at: 44))
    return end < UInt64(p.count) ? Data(p.prefix(Int(end))) : p
}

/// The package header (`package.HEADER`: magic "WP2A", abi, kind, abi_minor, name[24], version, size, entry,
/// relocations, crc, …).
public func parseHeader(_ d: Data) -> PackageHeader? {
    guard d.count >= headerSize, d.prefix(4) == Data("WP2A".utf8) else { return nil }
    let name = d[d.startIndex + 8..<d.startIndex + 32].prefix { $0 != 0 }
    return PackageHeader(kind: Int(d[d.startIndex + 6]), name: String(decoding: name, as: UTF8.self),
                         version: d.le(UInt32.self, at: 32), crc: d.le(UInt32.self, at: 48))
}

func check(_ r: Data) throws -> Data {
    guard let s = r.first else { throw InstallError.refused(0xFF) }
    if s == Status.busy.rawValue { throw InstallError.busy }
    guard s == Status.ok.rawValue else { throw InstallError.refused(s) }
    return Data(r.dropFirst())
}

/// Headers of the occupied slots (0…slots−1 and the loader).
public func installed(_ s: Requester, slots: Int) async throws -> [Int: PackageHeader] {
    var out: [Int: PackageHeader] = [:]
    for slot in Array(0..<slots) + [loaderSlot] {
        if let h = parseHeader(try check(try await s.call(Cmd.info, Data([UInt8(slot)])))) { out[slot] = h }
    }
    return out
}

/// Installs an app package into the slot of the same name, else the first free one, and a loader package
/// (kind 1) into slot L; returns the slot. `busy` while that app (or the loader's menu) runs on the watch.
/// An app's widget icon trailer goes to stub 10 as it is (the stub checks it and drops a broken one); an older stub
/// gets the package without it.
public func install(_ s: Requester, package: Data, progress: @Sendable (Double) -> Void) async throws -> Int {
    guard let pkg = parseHeader(package), pkg.kind == 0 || pkg.kind == 1 else { throw InstallError.notAPackage }
    let slot: Int
    var file = package
    if pkg.kind == 1 {
        slot = loaderSlot
    } else {
        let stub = try await stubVersion(s)
        if stub < trailerStub { file = stripTrailer(package) }
        let slots = appSlots(stub: stub)
        let used = try await installed(s, slots: slots)
        guard let free = used.first(where: { $0.key < slots && $0.value.name == pkg.name })?.key
            ?? (0..<slots).first(where: { used[$0] == nil }) else { throw InstallError.noFreeSlot(slots: slots) }
        slot = free
    }
    var begin = Data([UInt8(slot)])
    begin.le(UInt32(file.count))
    begin.le(crc32(file))
    _ = try check(try await s.call(Cmd.begin, begin))
    for off in stride(from: 0, to: file.count, by: dataMax) {
        var d = Data()
        d.le(UInt32(off))
        let end = min(off + dataMax, file.count)
        d += file[file.startIndex + off..<file.startIndex + end]
        let r = try check(try await s.call(Cmd.data, d))
        guard r.count == 4, r.le(UInt32.self, at: 0) == UInt32(end) else { throw InstallError.refused(0xFE) }
        progress(Double(end) / Double(file.count))
    }
    _ = try check(try await s.call(Cmd.end, Data([0])))
    return slot
}

/// Removes the app in `slot` with its data (stub DELETE). `busy` while that app runs on the watch.
public func remove(_ s: Requester, slot: Int) async throws {
    _ = try check(try await s.call(Cmd.delete, Data([UInt8(slot)])))
}

// MARK: Apps menu order (cmf-watch-sdk docs/app-order.md)

public enum OrderError: Error, Equatable {
    /// No single WP2ORDER table in the image, or one cut short: a loader older than the app order.
    case noTable
    /// Over 16 names, or a name not 1…23 UTF-8 bytes.
    case badNames
}

/// The loader package with the Apps menu order `names` (package names, first row first) in its WP2ORDER table,
/// re-signed: the image CRC at 0x30, then the header CRC at 0x34. Install it to slot 0xFF like any loader.
public func setOrder(_ package: Data, names: [String]) throws -> Data {
    var p = [UInt8](package)
    let magic = [UInt8]("WP2ORDER".utf8), fields = 16, field = 24
    let encoded = names.map { [UInt8]($0.utf8) }
    guard encoded.count <= fields, encoded.allSatisfy({ (1...23).contains($0.count) }) else { throw OrderError.badNames }
    guard p.count >= headerSize + magic.count else { throw OrderError.noTable }
    let hits = (headerSize...p.count - magic.count).filter { i in p[i] == magic[0] && Array(p[i..<i + magic.count]) == magic }
    guard hits.count == 1, hits[0] + magic.count + fields * field <= p.count else { throw OrderError.noTable }
    let t = hits[0] + magic.count
    let table = encoded.flatMap { $0 + [UInt8](repeating: 0, count: field - $0.count) }
    p.replaceSubrange(t..<t + fields * field, with: table + [UInt8](repeating: 0, count: fields * field - table.count))
    func put(_ v: UInt32, at o: Int) { for k in 0..<4 { p[o + k] = UInt8(v >> (8 * k) & 0xFF) } }
    put(crc32(Data(p[headerSize...])), at: 0x30)
    put(crc32(Data(p[..<0x34])), at: 0x34)
    return Data(p)
}
