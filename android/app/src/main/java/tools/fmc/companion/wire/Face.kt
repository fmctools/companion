package tools.fmc.companion.wire

// What fmc.tools checks before a watchface goes to the watch (fmc_frontend editor/core/format/bin.ts
// assertFlashable, flashWarning; device/lib/ble.ts uploadWatchface). Format: docs/cmf-protocol.md §9.6a.
// Port of ios/WireKit Face.swift.

/** Largest image side let onto the watch: a 1386×1386 AOD image boot-looped a Watch 3 Pro (`MAX_IMAGE_SIDE`). */
const val MAX_IMAGE_SIDE = 580

/** No factory face goes past this but one; beyond it the user confirms (`SAFE_IMAGE_SIDE`). */
const val SAFE_IMAGE_SIDE = 470
private const val FACE_HEADER = 36
private const val TAG_ROOT = 0x20
internal const val TAG_AOD = 0x22
internal const val TAG_PREVIEW = 0x28

/** `screens`: top-level screens, tag → tags of their children; `images`: (w, h) in file order. */
data class Face(val name: String, val screens: List<Pair<Int, List<Int>>>, val images: List<Pair<Int, Int>>)

sealed interface FaceVerdict {
    data object Ok : FaceVerdict

    /** An image larger than factory faces use: install only after the user accepts the risk. */
    data class Confirm(val w: Int, val h: Int) : FaceVerdict
    data class Refuse(val why: FaceRefusal) : FaceVerdict
}

sealed interface FaceRefusal {
    data object NotAWatchface : FaceRefusal
    data object TooLarge : FaceRefusal

    /** The always-on screen has no 0x28 thumbnail: the face that crash-looped a Watch 3 Pro on AOD (#49). */
    data object AodWithoutPreview : FaceRefusal
    data class ImageTooBig(val w: Int, val h: Int) : FaceRefusal

    /** A Watch 3 Pro screen that needs more of the watch's memory than [SCREEN_BUDGET] even after [fitForWatch]. */
    data class ScreenOverBudget(val aod: Boolean, val bytes: Int) : FaceRefusal

    /** A Watch 3 Pro face whose memory can't be counted ([measurable]). */
    data object Unmeasurable : FaceRefusal
}

private class Node(val tag: Int, val children: List<Int>?)

/** `parseTLV`: null when a node runs past the end; children only for values of 3+ bytes that parse. */
private fun tlv(d: ByteArray, depth: Int = 0): List<Node>? {
    val out = mutableListOf<Node>()
    var off = 0
    while (off < d.size) {
        if (off + 3 > d.size) return null
        val n = d.le16(off + 1)
        if (off + 3 + n > d.size) return null
        val v = d.copyOfRange(off + 3, off + 3 + n)
        val kids = if (n >= 3 && depth < 12) tlv(v, depth + 1)?.map { it.tag } else null
        out += Node(d.u8(off), kids)
        off += 3 + n
    }
    return out
}

/** `parseBin`, the parts the checks need; null for a file that does not parse. */
fun parseFace(d: ByteArray): Face? {
    if (d.size < 2 * FACE_HEADER + 3 || !hasFaceMagic(d)) return null
    if (!d.copyOf(FACE_HEADER).contentEquals(d.copyOfRange(d.size - FACE_HEADER, d.size))) return null
    val body = d.copyOfRange(FACE_HEADER, d.size - FACE_HEADER)
    if (body.u8(0) != TAG_ROOT) return null
    val rootLen = body.le16(1)
    if (3 + rootLen > body.size) return null
    val tree = tlv(body.copyOfRange(3, 3 + rootLen)) ?: return null
    val images = mutableListOf<Pair<Int, Int>>()
    var off = 3 + rootLen
    while (off < body.size) {
        if (off + 8 > body.size) return null
        val h = body.le32(off)
        val size = body.le32(off + 4)
        if (off + 8 + size > body.size) return null
        images += ((h shr 10) and 0x7FF).toInt() to ((h shr 21) and 0x7FF).toInt()
        off += 8 + size.toInt()
    }
    val name = d.copyOfRange(8, 0x18).takeWhile { it != 0.toByte() }.toByteArray()
    return Face(String(name), tree.map { it.tag to (it.children ?: emptyList()) }, images)
}

private fun hasFaceMagic(d: ByteArray) =
    d.size >= 36 && d.u8(4) == 1 && d.u8(5) == 0 && d.u8(6) == 0 && d.u8(7) in setOf(0, 2)

/** The name inside the file, when header and trailer agree (`uploadWatchface`'s own check). */
fun faceName(d: ByteArray): String? {
    if (!hasFaceMagic(d)) return null
    fun nul(off: Int): String? {
        if (off < 0) return null
        val e = (off until d.size).firstOrNull { d[it] == 0.toByte() } ?: return null
        return String(d.copyOfRange(off, e))
    }
    val name = nul(8)
    return if (!name.isNullOrEmpty() && name == nul(d.size - 28)) name else null
}

/**
 * Every install goes through this gate. It fails closed, exactly like the site: a file that does not parse goes to
 * no watch, one that can't be measured to no Watch 3 Pro. [watch3Pro]: the watch it goes to is one ([isWatch3Pro]);
 * run [fitForWatch] first, it shrinks what it can.
 */
fun checkFace(d: ByteArray, watch3Pro: Boolean = false): FaceVerdict {
    if (d.size > 32 shl 20) return FaceVerdict.Refuse(FaceRefusal.TooLarge)
    if (faceName(d) == null) return FaceVerdict.Refuse(FaceRefusal.NotAWatchface)
    val face = parseFace(d) ?: return FaceVerdict.Refuse(FaceRefusal.NotAWatchface)
    val bin = runCatching { parseBin(d) }.getOrNull() ?: return FaceVerdict.Refuse(FaceRefusal.NotAWatchface)
    val aod = face.screens.firstOrNull { it.first == TAG_AOD }
    if (aod != null && TAG_PREVIEW !in aod.second) return FaceVerdict.Refuse(FaceRefusal.AodWithoutPreview)
    face.images.firstOrNull { (w, h) -> w > MAX_IMAGE_SIDE || h > MAX_IMAGE_SIDE }
        ?.let { (w, h) -> return FaceVerdict.Refuse(FaceRefusal.ImageTooBig(w, h)) }
    if (watch3Pro && !measurable(bin)) return FaceVerdict.Refuse(FaceRefusal.Unmeasurable)
    if (watch3Pro) screenOverBudget(d)?.let { return FaceVerdict.Refuse(FaceRefusal.ScreenOverBudget(it.tag == TAG_AOD, it.bytes)) }
    face.images.firstOrNull { (w, h) -> w > SAFE_IMAGE_SIDE || h > SAFE_IMAGE_SIDE }
        ?.let { (w, h) -> return FaceVerdict.Confirm(w, h) }
    return FaceVerdict.Ok
}

/**
 * The dial id a face gets on the watch, from its catalog record id (else its name): a re-install lands on the id
 * it already has and replaces itself instead of taking another slot. FNV-1a, range 10000…2^31-1 (`dialId`).
 */
fun dialId(seed: String): Long {
    // the site hashes UTF-16 code units, as Kotlin chars are
    var h = 0x811C9DC5.toInt()
    for (c in seed) h = (h xor c.code) * 0x01000193
    return 10000 + (h.toUInt() % (0x7FFF_FFFFu - 10000u)).toLong()
}
