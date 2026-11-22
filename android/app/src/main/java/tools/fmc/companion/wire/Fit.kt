package tools.fmc.companion.wire

// How much RAM a screen of a face takes on a Watch 3 Pro, and the face made to fit it before it goes to the watch
// (fmc_frontend editor/core/format/budget.ts and fit.ts, fmctools/fmc #104). Port of ios/WireKit Fit.swift, which
// says why: the Watch 3 Pro decodes every image a screen shows into one ~6.5 MB heap and boot-loops when it runs out.
// ponytail: one image per reference, and the budget is the Watch 3 Pro's alone, as on the site.

/** Decoded bytes one screen's images may take on a Watch 3 Pro (`SCREEN_BUDGET`). */
const val SCREEN_BUDGET = 5_000_000

/** The site's `watchDevice(name) === "watch_3_pro"`: the advertised name is the only model id there is. */
fun isWatch3Pro(watchName: String?) = watchName != null && Regex("watch (3 pro|pro 3)", RegexOption.IGNORE_CASE).containsMatchIn(watchName)

/** Bytes the firmware allocates to hold a resource decoded, per colour format (`decodedBytes`). */
fun decodedBytes(cf: Int, w: Int, h: Int) = when (cf) {
    1, 4 -> w * h * 2 // JPEG decodes to RGB565
    5 -> w * h * 3
    13 -> ((w + 1) shr 1) * h
    14 -> w * h
    24 -> w * h * 4
    28 -> (((w + 3) shr 2) shl 2) * (((h + 3) shr 2) shl 2)
    else -> 0
}

private fun decodedBytes(r: FaceResource) = decodedBytes(r.cf, r.w, r.h)

/** Formats fitForWatch re-encodes as ETC2; JPEG stays JPEG (`TO_ETC2`). */
private val TO_ETC2 = setOf(4, 5, 24)

/** `shownResources`: the largest image of each reference, in walk order, the preview (0x28) subtree left out. */
fun shownResources(screen: FaceNode, res: List<FaceResource>): List<Int> {
    val shown = LinkedHashSet<Int>()
    fun walk(n: FaceNode) {
        if (n.tag == TAG_PREVIEW) return
        n.images?.takeIf { it.isNotEmpty() }?.let { images ->
            shown += images.drop(1).fold(images[0]) { a, b -> if (decodedBytes(res[b]) > decodedBytes(res[a])) b else a }
        }
        n.subs?.forEach(::walk)
    }
    walk(screen)
    return shown.toList()
}

fun screenBytes(screen: FaceNode, res: List<FaceResource>) = shownResources(screen, res).sumOf { decodedBytes(res[it]) }

/** [COMPRESSED]: over the budget as is, but fitForWatch gets it under. */
enum class ScreenFit(val site: String) { FITS("fits"), COMPRESSED("compressed"), TOO_HEAVY("too-heavy") }

/** `screenMemory`: what a screen takes on a Watch 3 Pro, and whether it gets on the watch at all. */
fun screenMemory(screen: FaceNode, res: List<FaceResource>): Pair<Int, ScreenFit> {
    val shown = shownResources(screen, res)
    val bytes = shown.sumOf { decodedBytes(res[it]) }
    val floor = shown.sumOf { val r = res[it]; if (r.cf in TO_ETC2) decodedBytes(28, r.w, r.h) else decodedBytes(r) }
    return bytes to when {
        bytes <= SCREEN_BUDGET -> ScreenFit.FITS
        floor <= SCREEN_BUDGET -> ScreenFit.COMPRESSED
        else -> ScreenFit.TOO_HEAVY
    }
}

/** The colour formats [decodedBytes] knows. */
private val MEASURED = setOf(1, 4, 5, 13, 14, 24, 28)

/** The tags that hold layers in every face of the catalog and both factory corpora (`CONTAINERS`). */
private val CONTAINERS = setOf(0x21, 0x22, 0x30, 0x38, 0x60, 0x68, 0x70, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x89)

/**
 * `measurable`: whether [screenBytes] sees everything the face shows. A screen or container that didn't parse into
 * layers, a reference that leads to no resource (kept as `tail`) or an unknown format would count as zero bytes.
 */
fun measurable(face: FaceBin): Boolean {
    fun ok(n: FaceNode, top: Boolean): Boolean {
        if (n.tag == TAG_PREVIEW) return true
        n.images?.let { images -> return images.all { face.resources[it].cf in MEASURED } }
        val opaque = n.hex?.isNotEmpty() == true
        if (n.tag == 0x01 && (opaque || n.tail?.any { it != 0.toByte() } == true)) return false
        if (opaque && (top || n.tag in CONTAINERS)) return false
        return n.subs?.all { ok(it, false) } ?: true
    }
    return face.screens.all { ok(it, true) }
}

class OverBudget(val screen: Int, val tag: Int, val bytes: Int)

/** `overBudget`: the screens a Watch 3 Pro can't hold (index into `screens`), with what each needs. */
fun overBudget(face: FaceBin) = face.screens.mapIndexedNotNull { i, s ->
    screenBytes(s, face.resources).takeIf { it > SCREEN_BUDGET }?.let { OverBudget(i, s.tag, it) }
}

class Fitted(val bin: ByteArray, val compressed: Int)

/**
 * `fitForWatch`: the file as it should go to the watch. Every model: cf 5 images without a transparent pixel become
 * cf 4 (lossless). A Watch 3 Pro screen still over its budget then has its largest shown cf 4/5/24 images re-encoded
 * as ETC2 until it fits (lossy, so only as far as needed). [Fitted.bin] is the input itself when nothing changed, a
 * file that doesn't parse comes back untouched (the gate decides about those); [Fitted.compressed] counts the images
 * re-encoded as ETC2. Takes seconds on a heavy face: not on the main thread.
 */
fun fitForWatch(bin: ByteArray, watch3Pro: Boolean): Fitted {
    val face = try { parseBin(bin) } catch (_: Exception) { return Fitted(bin, 0) }
    val res = face.resources
    var changed = false
    var compressed = 0
    for ((i, r) in res.withIndex()) {
        if (r.cf != 5) continue
        val px = decodePixels(r)
        if ((3 until px.size step 4).all { px[it] == 255 }) {
            res[i] = encodePixels(px, r.w, r.h, 4)
            changed = true
        }
    }
    if (watch3Pro) {
        for (s in overBudget(face)) {
            // sortedByDescending is stable, like the site's sort: of two equal images the first shown goes first
            val heaviest = shownResources(face.screens[s.screen], res).filter { res[it].cf in TO_ETC2 }
                .sortedByDescending { decodedBytes(res[it]) }
            for (i in heaviest) {
                if (overBudget(face).none { it.screen == s.screen }) break
                val r = res[i]
                res[i] = encodePixels(decodePixels(r), r.w, r.h, 28)
                changed = true
                compressed++
            }
        }
    }
    return Fitted(if (changed) buildBin(face) else bin, compressed)
}

/** The over-budget screen of a Watch 3 Pro face, if any (`assertFlashable`'s budget check). */
fun screenOverBudget(d: ByteArray): OverBudget? =
    try { overBudget(parseBin(d)).firstOrNull() } catch (_: Exception) { null }
