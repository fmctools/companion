import Foundation

// What fmc.tools checks before a watchface goes to the watch (fmc_frontend editor/core/format/bin.ts
// assertFlashable, flashWarning; device/lib/ble.ts uploadWatchface). Format: docs/cmf-protocol.md §9.6a.

/// Largest image side let onto the watch: a 1386×1386 AOD image boot-looped a Watch 3 Pro (`MAX_IMAGE_SIDE`).
public let maxImageSide = 580
/// No factory face goes past this but one; beyond it the user confirms (`SAFE_IMAGE_SIDE`).
public let safeImageSide = 470
let faceHeader = 36, tagRoot: UInt8 = 0x20, tagAod: UInt8 = 0x22, tagPreview: UInt8 = 0x28

public struct Face: Equatable, Sendable {
    public var name: String
    /// Top-level screens: tag and the tags of their children.
    public var screens: [(tag: UInt8, children: [UInt8])]
    /// Image sizes, in file order.
    public var images: [(w: Int, h: Int)]

    public static func == (a: Face, b: Face) -> Bool {
        a.name == b.name && a.screens.elementsEqual(b.screens) { $0.tag == $1.tag && $0.children == $1.children }
            && a.images.elementsEqual(b.images) { $0 == $1 }
    }
}

public enum FaceVerdict: Equatable, Sendable {
    case ok
    /// An image larger than factory faces use: install only after the user accepts the risk.
    case confirm(w: Int, h: Int)
    case refuse(FaceRefusal)
}

public enum FaceRefusal: Equatable, Sendable {
    case notAWatchface, tooLarge
    /// The always-on screen has no 0x28 thumbnail: the face that crash-looped a Watch 3 Pro on AOD (#49).
    case aodWithoutPreview
    case imageTooBig(w: Int, h: Int)
    /// A Watch 3 Pro screen that needs more of the watch's memory than `screenBudget` even after `fitForWatch`.
    case screenOverBudget(aod: Bool, bytes: Int)
    /// A Watch 3 Pro face whose memory can't be counted (`measurable`).
    case unmeasurable
}

/// `parseTLV`: nil when a node runs past the end; children only for values of 3+ bytes that parse.
func tlv(_ d: Data, depth: Int = 0) -> [(tag: UInt8, value: Data, children: [UInt8]?)]? {
    var out: [(tag: UInt8, value: Data, children: [UInt8]?)] = []
    var off = 0
    while off < d.count {
        guard off + 3 <= d.count else { return nil }
        let n = Int(d.le(UInt16.self, at: off + 1))
        guard off + 3 + n <= d.count else { return nil }
        let v = Data(d[d.startIndex + off + 3..<d.startIndex + off + 3 + n])
        let kids = n >= 3 && depth < 12 ? tlv(v, depth: depth + 1)?.map(\.tag) : nil
        out.append((d[d.startIndex + off], v, kids))
        off += 3 + n
    }
    return out
}

/// `parseBin`, the parts the checks need; nil for a file that does not parse.
public func parseFace(_ d: Data) -> Face? {
    guard d.count >= 2 * faceHeader + 3, hasFaceMagic(d),
          d.prefix(faceHeader) == d.suffix(faceHeader) else { return nil }
    let body = Data(d.dropFirst(faceHeader).dropLast(faceHeader))
    guard body[0] == tagRoot else { return nil }
    let rootLen = Int(body.le(UInt16.self, at: 1))
    guard 3 + rootLen <= body.count, let tree = tlv(body[3..<3 + rootLen]) else { return nil }
    var images: [(w: Int, h: Int)] = []
    var off = 3 + rootLen
    while off < body.count {
        guard off + 8 <= body.count else { return nil }
        let h = body.le(UInt32.self, at: off), size = Int(body.le(UInt32.self, at: off + 4))
        guard off + 8 + size <= body.count else { return nil }
        images.append((Int(h >> 10 & 0x7FF), Int(h >> 21 & 0x7FF)))
        off += 8 + size
    }
    let name = d[8..<0x18].prefix { $0 != 0 }
    return Face(name: String(decoding: name, as: UTF8.self), screens: tree.map { ($0.tag, $0.children ?? []) },
                images: images)
}

func hasFaceMagic(_ d: Data) -> Bool {
    d.count >= 36 && d[d.startIndex + 4] == 1 && d[d.startIndex + 5] == 0 && d[d.startIndex + 6] == 0
        && [0, 2].contains(d[d.startIndex + 7])
}

/// The name inside the file, when header and trailer agree (`uploadWatchface`'s own check).
public func faceName(_ d: Data) -> String? {
    guard hasFaceMagic(d) else { return nil }
    func nul(_ off: Int) -> String? {
        guard off >= 0, let e = d[(d.startIndex + off)...].firstIndex(of: 0) else { return nil }
        return String(decoding: d[(d.startIndex + off)..<e], as: UTF8.self)
    }
    guard let name = nul(8), !name.isEmpty, name == nul(d.count - 28) else { return nil }
    return name
}

/// Every install goes through this gate. It fails closed, exactly like the site: a file that does not parse goes to
/// no watch, one that can't be measured to no Watch 3 Pro. `watch3Pro`: the watch it goes to is one (`isWatch3Pro`);
/// run `fitForWatch` first, it shrinks what it can.
public func checkFace(_ d: Data, watch3Pro: Bool = false) -> FaceVerdict {
    guard d.count <= 32 << 20 else { return .refuse(.tooLarge) }
    guard faceName(d) != nil else { return .refuse(.notAWatchface) }
    guard let face = parseFace(d), let bin = try? parseBin(d) else { return .refuse(.notAWatchface) }
    if let aod = face.screens.first(where: { $0.tag == tagAod }), !aod.children.contains(tagPreview) {
        return .refuse(.aodWithoutPreview)
    }
    if let big = face.images.first(where: { $0.w > maxImageSide || $0.h > maxImageSide }) {
        return .refuse(.imageTooBig(w: big.w, h: big.h))
    }
    if watch3Pro, !measurable(bin) { return .refuse(.unmeasurable) }
    if watch3Pro, let heavy = screenOverBudget(d) {
        return .refuse(.screenOverBudget(aod: heavy.tag == tagAod, bytes: heavy.bytes))
    }
    if let big = face.images.first(where: { $0.w > safeImageSide || $0.h > safeImageSide }) {
        return .confirm(w: big.w, h: big.h)
    }
    return .ok
}

/// The dial id a face gets on the watch, from its catalog record id (else its name): a re-install lands on the id
/// it already has and replaces itself instead of taking another slot. FNV-1a, range 10000…2^31-1 (`dialId`).
public func dialId(_ seed: String) -> UInt32 {
    // the site hashes UTF-16 code units
    let h = seed.utf16.reduce(UInt32(0x811C_9DC5)) { ($0 ^ UInt32($1)) &* 0x0100_0193 }
    return 10000 + h % (0x7FFF_FFFF - 10000)
}
