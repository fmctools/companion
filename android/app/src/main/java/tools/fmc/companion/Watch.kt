package tools.fmc.companion

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import tools.fmc.companion.wire.DialCount
import tools.fmc.companion.wire.FaceRefusal
import tools.fmc.companion.wire.FaceVerdict
import tools.fmc.companion.wire.Fitted
import tools.fmc.companion.wire.KSession
import tools.fmc.companion.wire.LoaderState
import tools.fmc.companion.wire.MAX_IMAGE_SIDE
import tools.fmc.companion.wire.PackageHeader
import tools.fmc.companion.wire.SCREEN_BUDGET
import tools.fmc.companion.wire.StockSession
import tools.fmc.companion.wire.Stub
import tools.fmc.companion.wire.UploadError
import tools.fmc.companion.wire.WireError
import tools.fmc.companion.wire.checkFace
import tools.fmc.companion.wire.dialId
import tools.fmc.companion.wire.fitForWatch
import tools.fmc.companion.wire.hex
import tools.fmc.companion.wire.hexOrNull
import tools.fmc.companion.wire.installFace
import tools.fmc.companion.wire.isWatch3Pro
import tools.fmc.companion.wire.readLoader

// What the app does with the watch, as ios/App WatchModel.swift and FaceInstall.swift.

/**
 * Is the App Loader on the watch? Read only: K from the shell, then INFO (fmc_frontend ble.ts readWp2). null = stock
 * firmware (or a stub from before 2026-11-13, which has no K). On the watch: `AT GETSECRET` and INFO, nothing else.
 */
suspend fun readWatch(context: Context, store: SecureStore): LoaderState? {
    val link = BleLink(context)
    try {
        return withTimeout(30_000) {
            link.connect()
            AppOrder.watch(context, link.watchId)
            val account = "k-${link.watchId}"
            val cached = store[account]
            val (session, secret) = KSession.open(link, cached, register = false)
            store[account] = secret
            readLoader(session)?.let { return@withTimeout it }
            // K changes with a factory reset: a cached one that gets no answer is read again once, and only asked
            // again when it really changed (FMC Systems' review of the iOS app: no second 2.5 s on stock watches)
            if (cached == null) return@withTimeout null
            val (fresh, newSecret) = KSession.open(link, register = false)
            if (newSecret == cached) return@withTimeout null
            store[account] = newSecret
            readLoader(fresh)
        }
    } finally {
        link.disconnect()
    }
}

class FaceInstallError(message: String) : Exception(message)

fun refusalText(why: FaceRefusal) = when (why) {
    FaceRefusal.AodWithoutPreview ->
        str(R.string.refusal_aod)
    is FaceRefusal.ImageTooBig ->
        str(R.string.refusal_image_too_big, why.w, why.h, MAX_IMAGE_SIDE)
    is FaceRefusal.ScreenOverBudget ->
        str(if (why.aod) R.string.refusal_over_budget_aod else R.string.refusal_over_budget_main, mb(why.bytes), mb(SCREEN_BUDGET))
    FaceRefusal.Unmeasurable -> str(R.string.refusal_unmeasurable)
    else -> str(R.string.refusal_not_face)
}

/** The site's `toFixed(1)` of megabytes, in the user's locale. */
private fun mb(bytes: Int) = "%.1f".format(bytes / 1e6)

/**
 * [fitForWatch] for the watch on the line, then the gate again with its model (ble.model.ts flashFx): a Watch 3 Pro
 * gets its heaviest images as ETC2, or a refusal for a screen that still doesn't fit. Seconds on a heavy face: off
 * the main thread.
 */
suspend fun fitFace(bin: ByteArray, watchName: String?): Fitted = withContext(Dispatchers.Default) {
    val w3 = isWatch3Pro(watchName)
    val fitted = fitForWatch(bin, w3)
    val verdict = checkFace(fitted.bin, w3)
    if (verdict is FaceVerdict.Refuse) throw FaceInstallError(refusalText(verdict.why))
    fitted
}

/** The file and the gate's verdict: nothing goes to the watch before the user has seen it. */
suspend fun fetchFace(face: Watchface): Pair<ByteArray, FaceVerdict> {
    val url = face.binURL ?: throw FaceInstallError(str(R.string.face_no_file))
    val bin = download(url)
    val verdict = checkFace(bin)
    if (verdict is FaceVerdict.Refuse) throw FaceInstallError(refusalText(verdict.why))
    return bin to verdict
}

/**
 * A watchface onto the watch the way fmc.tools does it through Chrome's Web Bluetooth (ble.ts connect, pair,
 * authenticate, uploadWatchface). The stock session can't share the watch with Nothing X, so the user closes
 * Nothing X first, and may have to add the watch to it again afterwards (fmc issue #27); the UI says so first.
 */
/** A dial on the watch. [index]: its place in the watch's own carousel, the only handle on a dial nobody named. */
/**
 * The watch only reports ids: faces this app installed keep their name and preview, stock ones are named from
 * fmc.tools' stock-dials.json, Nothing X gallery ones have nothing to go on.
 */
data class DialSlot(val id: Long, val index: Int, val name: String?, val preview: String? = null) {
    val label get() = name ?: str(R.string.face_slot, index + 1)
}

/** fmc_frontend modules/device/lib/stock-dials.json (assets): id → name of the factory and Nothing gallery faces. */
private var stock: Map<Long, String>? = null

fun stockDials(context: Context): Map<Long, String> = stock ?: runCatching {
    val j = org.json.JSONObject(context.assets.open("stock-dials.json").bufferedReader().readText())
    j.keys().asSequence().associate { it.toLong() to j.getJSONObject(it).getString("name") }
}.getOrDefault(emptyMap()).also { stock = it }

private fun slot(context: Context, prefs: android.content.SharedPreferences, id: Long, i: Int) =
    DialSlot(id, i, prefs.getString("name-$id", null) ?: stockDials(context)[id], prefs.getString("preview-$id", null))

/** The watch's faces as the last install from this app saw them. */
class FacesOnWatch(
    val faces: List<DialSlot>,
    /** epoch ms, 0 = never */
    val at: Long,
    /** "6 of 7" from the a055 header, side-loaded dials included */
    val count: String?,
    val header: String,
    /** Every entry of the last a055, the photo face included. */
    val all: List<Long>,
) {
    /** The face on screen: a055 byte 1 indexes the full list (cmf-watch-sdk docs/recon.md, "Stock watch faces"). */
    val active get() = header.split(" ").getOrNull(1)?.toIntOrNull(16)?.let { all.getOrNull(it) }
}

fun facesOnWatch(context: Context): FacesOnWatch {
    val prefs = context.getSharedPreferences("dials", Context.MODE_PRIVATE)
    val ids = prefs.getString("faces-on-watch", "")!!.split(",").mapNotNull { it.toLongOrNull() }
    return FacesOnWatch(
        ids.mapIndexed { i, d -> slot(context, prefs, d, i) },
        prefs.getLong("faces-on-watch-date", 0),
        prefs.getString("faces-on-watch-count", null)?.split(",")?.let { (n, c) -> "$n of $c" },
        prefs.getString("faces-on-watch-header", "")!!,
        prefs.getString("faces-on-watch-all", "")!!.split(",").mapNotNull { it.toLongOrNull() },
    )
}

/** ble.ts WF_CAPACITY */
// ponytail: the watch takes 6; a055's 4th byte says 7 (a built-in face?), so it is ignored
const val CAPACITY = 6

/**
 * Connects and opens a stock session (a new bind only when the saved key is refused, and [bind] allows one: it
 * pops up on the watch), then [body]. [before] sees the link before anything is sent: it can still refuse.
 */
internal suspend fun <T> withStockSession(
    context: Context, store: SecureStore, bind: Boolean = true, before: suspend (BleLink) -> Unit = {},
    body: suspend (StockSession, String) -> T,
): T {
    val link = BleLink(context)
    try {
        withTimeout(30_000) { link.connect(scan = true) }
        before(link)
        val watch = link.watchId
        var secret = store["k-$watch"]
        if (secret == null) {
            secret = KSession.open(link, register = false).second
            store["k-$watch"] = secret
        }
        val session = StockSession(link)
        try {
            val saved = store["stock-$watch"]?.let(::hexOrNull) ?: throw UploadError.AuthFailed
            session.authenticate(saved)
        } catch (e: Exception) {
            if (!bind || e !is UploadError.AuthFailed && e !is WireError.Timeout) throw e
            // no key yet, or the watch was bound again since (Nothing X, a reset): bind, as the site does
            val k1 = session.pair(hexOrNull(secret) ?: ByteArray(0))
            store["stock-$watch"] = k1.hex()
        }
        return body(session, "$watch") // the keys were "dials-$watch" before: null stays "null"
    } finally {
        link.disconnect()
    }
}

private class Dials(val mine: List<Long>, val installed: List<Long>, val counted: DialCount?, val header: String)

/** What the watch reported in a055, plus the dials this app put there that the list leaves out. */
private suspend fun dials(context: Context, session: StockSession, watch: String): Dials {
    val prefs = context.getSharedPreferences("dials", Context.MODE_PRIVATE)
    val mine = prefs.getString("dials-$watch", "")!!.split(",").mapNotNull { it.toLongOrNull() }
    val reported = session.installedDials() ?: emptyList()
    val installed = reported + mine.filter { it !in reported }
    // the header counts side-loaded dials too; the hardcoded capacity and the id list are the fallback
    val header = (session.dialHeader ?: ByteArray(0)).joinToString(" ") { "%02x".format(it) }
    Log.i("dials", "a055 header $header, ${reported.size} listed, ${installed.size} known")
    return Dials(mine, installed, session.dialCount, header)
}

/** What the Watch tab shows. */
private fun remember(context: Context, onWatch: List<Long>, count: Int?, capacity: Int, header: String, all: List<Long>? = null) {
    context.getSharedPreferences("dials", Context.MODE_PRIVATE).edit()
        .apply { all?.let { putString("faces-on-watch-all", it.joinToString(",")) } }
        .putString("faces-on-watch", onWatch.joinToString(",")).putLong("faces-on-watch-date", System.currentTimeMillis())
        .putString("faces-on-watch-count", count?.let { "$it,$capacity" })
        .putString("faces-on-watch-header", header)
        .apply()
}

/**
 * Reads the dials off the watch for the Watch tab. [bind]: when the saved key is missing or refused, bind (a popup on
 * the watch, and Nothing X loses the watch, like an install); else that throws AuthFailed or Timeout.
 */
suspend fun readFacesOnWatch(context: Context, store: SecureStore, bind: Boolean) = withStockSession(context, store, bind) { session, watch ->
    val d = dials(context, session, watch)
    remember(context, d.installed, d.counted?.count, CAPACITY, d.header, session.listed)
}

/** Shows [id] on the watch. */
suspend fun activateFace(context: Context, store: SecureStore, id: Long) =
    editFaces(context, store) { all, _ -> all.indexOf(id).takeIf { it >= 0 }?.let { all to it } }

/**
 * Takes [id] off the watch; the face on screen stays, or the first one if it was that. A downloaded face's file goes at
 * the watch's next boot or upload; built-in faces stay on it, unlisted.
 */
suspend fun deleteFace(context: Context, store: SecureStore, id: Long) = editFaces(context, store) { all, active ->
    val kept = all.filter { it != id }
    if (kept.size == all.size) null else kept to (active?.let { all.getOrNull(it) }?.let(kept::indexOf)?.takeIf { it >= 0 } ?: 0)
}

/** Reads the full list, sends `change(list, active index)` (null: nothing to do), saves what the watch reports. */
private suspend fun editFaces(context: Context, store: SecureStore, change: (List<Long>, Int?) -> Pair<List<Long>, Int>?) =
    withStockSession(context, store) { session, watch ->
        session.installedDials()
        val active = session.dialHeader?.getOrNull(1)?.toInt()?.and(0xFF)
        change(session.listed ?: emptyList(), active)?.let { (ids, i) ->
            session.setDials(ids, i)
            // a face taken off is no longer this app's either
            val prefs = context.getSharedPreferences("dials", Context.MODE_PRIVATE)
            val listed = session.listed ?: emptyList()
            val mine = prefs.getString("dials-$watch", "")!!.split(",").mapNotNull { it.toLongOrNull() }
            prefs.edit().putString("dials-$watch", mine.filter { it in listed }.joinToString(",")).apply()
        }
        val d = dials(context, session, watch)
        remember(context, d.installed, d.counted?.count, CAPACITY, d.header, session.listed)
    }

/**
 * The dials to pick from before connecting: the watch was full when last read and this face isn't on it. null: room,
 * or never read; the install finds out on the watch.
 */
fun knownFull(context: Context, seed: String): List<DialSlot>? {
    val on = facesOnWatch(context)
    val ids = on.faces.map { it.id }
    val count = context.getSharedPreferences("dials", Context.MODE_PRIVATE).getString("faces-on-watch-count", null)
        ?.split(",")?.mapNotNull { it.toIntOrNull() }
    val full = (count?.firstOrNull() ?: ids.size) >= CAPACITY
    return if (full && ids.isNotEmpty() && dialId(seed) !in ids) on.faces else null
}

/**
 * Uploads [file], fitted to the watch first ([fitFace]). [preset]: the dial to replace, picked before connecting
 * ([knownFull]); [pick]: the watch is full and nothing was picked yet, which dial goes; null cancels the install.
 * Returns how many images were compressed to fit the watch's memory.
 */
suspend fun installFaceOnWatch(
    context: Context, store: SecureStore, file: ByteArray, seed: String, name: String,
    pick: suspend (List<DialSlot>) -> Long?, preset: Long? = null, progress: (Int) -> Unit,
): Int {
    var fitted = Fitted(file, 0)
    withStockSession(context, store, before = { fitted = fitFace(file, it.watchName) }) { session, watch ->
        val bin = fitted.bin
        val prefs = context.getSharedPreferences("dials", Context.MODE_PRIVATE)
        val d = dials(context, session, watch)
        val installed = d.installed
        val cap = CAPACITY
        val full = (d.counted?.count ?: installed.size) >= CAPACITY
        // which dial to replace (ble.ts NoFreeSlotError, slot-dialog.svelte)
        suspend fun ask() = pick(installed.mapIndexed { i, id -> slot(context, prefs, id, i) })
            ?: throw CancellationException("no dial picked")
        // full and not a re-install of this face: ask before sending anything
        // a pick made from a stale list stands only while that dial is still there
        var slot: Long? = preset?.takeIf { it in installed } ?: if (full && dialId(seed) !in installed) ask() else null
        val id = try {
            try {
                installFace(session, bin, seed, installed, cap, slot, progress = progress)
            } catch (e: UploadError.NoFreeSlot) {
                if (slot != null || installed.isEmpty()) throw e
                // the count said there was room and the watch said no: the header reading is wrong, or it is missing
                slot = ask()
                installFace(session, bin, seed, installed, cap, slot, progress = progress)
            }
        } catch (_: UploadError.NoFreeSlot) {
            throw FaceInstallError(str(R.string.watch_full_error))
        }
        val now = d.mine.filter { it != slot } + if (id in d.mine) emptyList() else listOf(id)
        prefs.edit().putString("dials-$watch", now.joinToString(",")).putString("name-$id", name).apply()
        val onWatch = slot?.let { sl -> installed.map { if (it == sl) id else it } }
            ?: if (id in installed) installed else installed + id
        remember(context, onWatch, d.counted?.let { if (slot != null || id in installed) it.count else it.count + 1 }, cap, d.header)
    }
    return fitted.compressed
}

/** The services' link has the watch again after a drop; AppModel reads it again (debounced). */
object WatchLink {
    val back = kotlinx.coroutines.flow.MutableSharedFlow<Unit>(extraBufferCapacity = 1)
}
