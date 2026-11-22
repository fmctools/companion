import Foundation

// How much RAM a screen of a face takes on a Watch 3 Pro, and the face made to fit it before it goes to the watch
// (fmc_frontend editor/core/format/budget.ts and fit.ts, fmctools/fmc #104).
//
// The Watch 3 Pro (stock 1.0.1.77) decodes every image a screen shows into one ~6.5 MB heap it shares with the
// framebuffer and keeps it decoded while the screen is up; when an allocation there fails the firmware crashes on
// purpose, loads the same face on the next boot, and boot-loops. Measured in the cmf-watch-utils emulator.
// ponytail: one image per reference (a digit set or a frame run counts its largest frame once), and the budget is
// the Watch 3 Pro's alone: the Watch Pro 2 has a slightly larger heap and nothing has crashed there, as on the site.

/// Decoded bytes one screen's images may take on a Watch 3 Pro (`SCREEN_BUDGET`).
public let screenBudget = 5_000_000

/// The site's `watchDevice(name) === "watch_3_pro"`: the advertised name is the only model id there is.
public func isWatch3Pro(_ watchName: String?) -> Bool {
    watchName?.range(of: "watch (3 pro|pro 3)", options: [.regularExpression, .caseInsensitive]) != nil
}

/// Bytes the firmware allocates to hold a resource decoded, per colour format (`decodedBytes`).
func decodedBytes(cf: Int, w: Int, h: Int) -> Int {
    switch cf {
    case 1, 4: w * h * 2 // JPEG decodes to RGB565
    case 5: w * h * 3
    case 13: ((w + 1) >> 1) * h
    case 14: w * h
    case 24: w * h * 4
    case 28: (((w + 3) >> 2) << 2) * (((h + 3) >> 2) << 2)
    default: 0
    }
}

private func decodedBytes(_ r: FaceResource) -> Int { decodedBytes(cf: r.cf, w: r.w, h: r.h) }

/// Formats fitForWatch re-encodes as ETC2; JPEG stays JPEG (`TO_ETC2`).
private let toEtc2 = [4, 5, 24]

/// `shownResources`: the largest image of each reference, in walk order, the preview (0x28) subtree left out.
func shownResources(_ screen: FaceNode, _ res: [FaceResource]) -> [Int] {
    var shown: [Int] = []
    func walk(_ n: FaceNode) {
        if n.tag == tagPreview { return }
        if let images = n.images, let first = images.first {
            let big = images.dropFirst().reduce(first) { decodedBytes(res[$1]) > decodedBytes(res[$0]) ? $1 : $0 }
            if !shown.contains(big) { shown.append(big) }
        }
        n.subs?.forEach(walk)
    }
    walk(screen)
    return shown
}

func screenBytes(_ screen: FaceNode, _ res: [FaceResource]) -> Int {
    shownResources(screen, res).reduce(0) { $0 + decodedBytes(res[$1]) }
}

public enum ScreenFit: String, Sendable {
    /// over the budget as is, but fitForWatch gets it under
    case fits, compressed, tooHeavy = "too-heavy"
}

/// `screenMemory`: what a screen takes on a Watch 3 Pro, and whether it gets on the watch at all.
public func screenMemory(_ screen: FaceNode, _ res: [FaceResource]) -> (bytes: Int, fit: ScreenFit) {
    let shown = shownResources(screen, res)
    let bytes = shown.reduce(0) { $0 + decodedBytes(res[$1]) }
    let floor = shown.reduce(0) { n, i in
        n + (toEtc2.contains(res[i].cf) ? decodedBytes(cf: 28, w: res[i].w, h: res[i].h) : decodedBytes(res[i]))
    }
    return (bytes, bytes <= screenBudget ? .fits : floor <= screenBudget ? .compressed : .tooHeavy)
}

/// The colour formats `decodedBytes` knows.
private let measured: Set<Int> = [1, 4, 5, 13, 14, 24, 28]
/// The tags that hold layers in every face of the catalog and both factory corpora (`CONTAINERS`).
private let containers: Set<UInt8> = [0x21, 0x22, 0x30, 0x38, 0x60, 0x68, 0x70, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x89]

/// `measurable`: whether `screenBytes` sees everything the face shows. A screen or container that didn't parse into
/// layers, a reference that leads to no resource (kept as `tail`) or an unknown format would count as zero bytes.
func measurable(_ face: FaceBin) -> Bool {
    func ok(_ n: FaceNode, top: Bool) -> Bool {
        if n.tag == tagPreview { return true }
        if let images = n.images { return images.allSatisfy { measured.contains(face.resources[$0].cf) } }
        let opaque = n.hex?.isEmpty == false
        if n.tag == 0x01, opaque || n.tail?.contains(where: { $0 != 0 }) == true { return false }
        if opaque, top || containers.contains(n.tag) { return false }
        return n.subs?.allSatisfy { ok($0, top: false) } ?? true
    }
    return face.screens.allSatisfy { ok($0, top: true) }
}

/// `overBudget`: the screens a Watch 3 Pro can't hold (index into `screens`), with what each needs.
func overBudget(_ face: FaceBin) -> [(screen: Int, tag: UInt8, bytes: Int)] {
    face.screens.indices.compactMap { i in
        let bytes = screenBytes(face.screens[i], face.resources)
        return bytes > screenBudget ? (i, face.screens[i].tag, bytes) : nil
    }
}

/// `fitForWatch`: the file as it should go to the watch. Every model: cf 5 images without a transparent pixel become
/// cf 4 (lossless). A Watch 3 Pro screen still over its budget then has its largest shown cf 4/5/24 images
/// re-encoded as ETC2 until it fits (lossy, so only as far as needed). `bin` is the input itself when nothing
/// changed, a file that doesn't parse comes back untouched (the gate decides about those); `compressed` counts the
/// images re-encoded as ETC2. Takes seconds on a heavy face: not on the main thread.
public func fitForWatch(_ bin: Data, watch3Pro: Bool) throws -> (bin: Data, compressed: Int) {
    guard var face = try? parseBin(bin) else { return (bin, 0) }
    var changed = false, compressed = 0
    for (i, r) in face.resources.enumerated() where r.cf == 5 {
        let px = try decodePixels(r)
        if stride(from: 3, to: px.count, by: 4).allSatisfy({ px[$0] == 255 }) {
            face.resources[i] = try encodePixels(px, r.w, r.h, 4)
            changed = true
        }
    }
    if watch3Pro {
        for (s, _, _) in overBudget(face) {
            let shown = shownResources(face.screens[s], face.resources).filter { toEtc2.contains(face.resources[$0].cf) }
            // stable, like the site's sort: of two equal images the first shown goes first
            let heaviest = shown.enumerated().sorted {
                let (a, b) = (decodedBytes(face.resources[$0.element]), decodedBytes(face.resources[$1.element]))
                return a != b ? a > b : $0.offset < $1.offset
            }.map(\.element)
            for i in heaviest {
                guard overBudget(face).contains(where: { $0.screen == s }) else { break }
                let r = face.resources[i]
                face.resources[i] = try encodePixels(decodePixels(r), r.w, r.h, 28)
                changed = true
                compressed += 1
            }
        }
    }
    return (changed ? try buildBin(face) : bin, compressed)
}

/// The over-budget screen of a Watch 3 Pro face, if any (`assertFlashable`'s budget check).
func screenOverBudget(_ d: Data) -> (tag: UInt8, bytes: Int)? {
    guard let face = try? parseBin(d), let s = overBudget(face).first else { return nil }
    return (s.tag, s.bytes)
}
