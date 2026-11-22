package tools.fmc.companion

import android.annotation.SuppressLint
import android.app.Notification
import android.content.ContentUris
import android.content.Context
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import android.os.SystemClock
import android.provider.CalendarContract.Attendees
import android.provider.CalendarContract.Events
import android.provider.CalendarContract.Instances
import android.service.notification.NotificationListenerService
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit
import java.util.Locale
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import tools.fmc.companion.wire.Event
import tools.fmc.companion.wire.HTTP_BODY_MAX
import tools.fmc.companion.wire.HttpCall
import tools.fmc.companion.wire.KeyValueStore
import tools.fmc.companion.wire.RefreshJob
import tools.fmc.companion.wire.RpcState
import tools.fmc.companion.wire.httpHost
import tools.fmc.companion.wire.MediaAction
import tools.fmc.companion.wire.NowPlaying
import tools.fmc.companion.wire.mediaRecord
import tools.fmc.companion.wire.parseAlert
import tools.fmc.companion.wire.parseHttpCall
import tools.fmc.companion.wire.requestHeaders
import tools.fmc.companion.wire.Method
import tools.fmc.companion.wire.Phone
import tools.fmc.companion.wire.RpcError
import tools.fmc.companion.wire.RpcStatus
import tools.fmc.companion.wire.batteryRecord
import tools.fmc.companion.wire.calendarRecord
import tools.fmc.companion.wire.eventTimes
import tools.fmc.companion.wire.httpRecords
import tools.fmc.companion.wire.locationRecord
import tools.fmc.companion.wire.notificationRecord
import tools.fmc.companion.wire.rgb565
import tools.fmc.companion.wire.u8
import tools.fmc.companion.wire.weatherArgs
import tools.fmc.companion.wire.weatherCard

// The miniapp services on Android (docs/miniapp-rpc.md, "Methods"). The dispatcher (wire/Rpc.kt answer) has
// checked the grant and the OS permission before any of these runs.

@SuppressLint("MissingPermission") // osAllows checked by the dispatcher
class PhoneServices(private val context: Context, private val grants: Grants) : Phone {
    override fun grants(pkg: String) = grants.of(pkg)
    override fun osAllows(cap: String) = osAllows(context, cap)
    override fun ask(pkg: String, cap: String, write: Boolean) {
        if (grants.markAsked(pkg, cap)) notifyAsk(context, pkg, cap, write)
    }

    override val state = RpcState(appStorage(context))
    override fun saveJob(pkg: String, job: RefreshJob) = Jobs(context).save(pkg, job)
    override fun deleteJob(pkg: String, id: Int) = Jobs(context).delete(pkg, id)

    override suspend fun call(pkg: String, method: Int, args: ByteArray): List<ByteArray> {
        val show = grants.showText(pkg)
        return when (method) {
            Method.CALENDAR -> calendar(args[0].toInt().coerceIn(-120, 120), args.u8(1).coerceIn(1, 7), args.u8(2).coerceIn(1, 20), show)
            Method.LOCATION -> location().let { (l, place) ->
                listOf(locationRecord(l.latitude, l.longitude, ageMin(l), place))
            }
            Method.WEATHER -> weatherArgs(args)!!.let { (days, hours) -> weather(days.coerceAtMost(7), hours) }
            Method.HTTP -> http(pkg, HttpCall("GET", String(args), httpHost(args)!!))
            Method.HTTP_REQUEST -> http(pkg, parseHttpCall(args)!!)
            Method.NOTIFICATIONS -> NotificationWatcher.records(context, args.u8(0).coerceIn(1, 10), show)
            Method.MEDIA -> nowPlaying()?.let { listOf(mediaRecord(it)) } ?: emptyList()
            Method.MEDIA_CONTROL -> emptyList<ByteArray>().also { control(args.u8(0)) }
            Method.NOTIFY -> emptyList<ByteArray>().also { postAlert(context, pkg, parseAlert(args)!!) }
            Method.BATTERY -> context.getSystemService(android.os.BatteryManager::class.java).let { b ->
                val level = b.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
                if (level !in 0..100) throw RpcError(RpcStatus.UNAVAILABLE)
                val plugged = context.registerReceiver(null, android.content.IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED))
                    ?.getIntExtra(android.os.BatteryManager.EXTRA_PLUGGED, 0) ?: 0
                listOf(batteryRecord(level, plugged != 0))
            }
            else -> throw RpcError(RpcStatus.BAD_REQUEST)
        }
    }

    /** The session that plays, else the first one; needs the notification listener (osAllows "media"). */
    private fun session(): android.media.session.MediaController? = runCatching {
        context.getSystemService(android.media.session.MediaSessionManager::class.java)
            .getActiveSessions(android.content.ComponentName(context, NotificationWatcher::class.java))
    }.getOrNull()?.let { list -> list.firstOrNull { it.playbackState?.state == android.media.session.PlaybackState.STATE_PLAYING } ?: list.firstOrNull() }

    private fun nowPlaying(): NowPlaying? {
        val c = session() ?: return null
        val s = c.playbackState
        val m = c.metadata
        val playing = s?.state == android.media.session.PlaybackState.STATE_PLAYING
        // the position as of the last update, moved on by the time since while it plays
        val pos = s?.position?.takeIf { it >= 0 }?.let {
            if (playing) it + ((SystemClock.elapsedRealtime() - s.lastPositionUpdateTime) * s.playbackSpeed).toLong() else it
        }
        val dur = m?.getLong(android.media.MediaMetadata.METADATA_KEY_DURATION)?.takeIf { it > 0 }
        val pm = context.packageManager
        val app = runCatching { pm.getApplicationLabel(pm.getApplicationInfo(c.packageName, 0)).toString() }.getOrDefault(c.packageName)
        return NowPlaying(playing, pos?.div(1000), dur?.div(1000), app,
            m?.getString(android.media.MediaMetadata.METADATA_KEY_TITLE).orEmpty(),
            m?.getString(android.media.MediaMetadata.METADATA_KEY_ARTIST).orEmpty())
    }

    private fun control(action: Int) {
        val c = session() ?: throw RpcError(RpcStatus.UNAVAILABLE)
        val t = c.transportControls
        val playing = c.playbackState?.state == android.media.session.PlaybackState.STATE_PLAYING
        when (action) {
            MediaAction.PLAY -> t.play()
            MediaAction.PAUSE -> t.pause()
            MediaAction.TOGGLE -> if (playing) t.pause() else t.play()
            MediaAction.NEXT -> t.skipToNext()
            else -> t.skipToPrevious()
        }
    }

    /** With the user's headers for (pkg, host) and its cookie jar; neither goes to the watch or the log. */
    private suspend fun http(pkg: String, c: HttpCall): List<ByteArray> {
        val (code, body) = fetch(c.url, max = HTTP_BODY_MAX, method = c.method, body = c.body,
            headers = requestHeaders(grants.headers(pkg, c.host), c.body), cookies = Cookies.of(pkg, c.host))
        return httpRecords(code, body)
    }

    private fun calendar(fromDay: Int, days: Int, limit: Int, show: Boolean): List<ByteArray> {
        val now = ZonedDateTime.now()
        val today = now.toLocalDate()
        val first = today.plusDays(fromDay.toLong())
        val end = first.plusDays(days.toLong())
        val fromMs = first.atStartOfDay(now.zone).toInstant().toEpochMilli()
        val toMs = end.atStartOfDay(now.zone).toInstant().toEpochMilli()
        // all-day instances sit at UTC midnight: a day wider on both sides, then kept by the days they cover
        val uri = Instances.CONTENT_URI.buildUpon().also {
            ContentUris.appendId(it, fromMs - DAY_MS)
            ContentUris.appendId(it, toMs + DAY_MS)
        }.build()
        val cols = arrayOf(Instances.BEGIN, Instances.END, Instances.ALL_DAY, Instances.TITLE, Instances.DISPLAY_COLOR,
            Instances.STATUS, Instances.SELF_ATTENDEE_STATUS)
        val events = mutableListOf<Event>()
        context.contentResolver.query(uri, cols, "${Instances.VISIBLE} = 1", null, null)?.use { c ->
            while (c.moveToNext()) {
                val begin = c.getLong(0)
                val finish = c.getLong(1)
                val allDay = c.getInt(2) != 0
                val tentative = c.getInt(5) == Events.STATUS_TENTATIVE || c.getInt(6) == Attendees.ATTENDEE_STATUS_TENTATIVE
                val color = rgb565(c.getInt(4))
                val title = c.getString(3).orEmpty()
                events += if (allDay) {
                    val s = Instant.ofEpochMilli(begin).atZone(ZoneOffset.UTC).toLocalDate()
                    val e = Instant.ofEpochMilli(finish).atZone(ZoneOffset.UTC).toLocalDate().coerceAtLeast(s.plusDays(1))
                    if (s >= end || e <= first) continue
                    val n = ChronoUnit.DAYS.between(s, e).toInt()
                    Event(ChronoUnit.DAYS.between(today, s).toInt(), 0, minOf(1440 * n, 0xFFFF), true, tentative, color, title)
                } else {
                    if (begin >= toMs || finish <= fromMs) continue
                    val (day, start, duration) = eventTimes(now, Instant.ofEpochMilli(begin), Instant.ofEpochMilli(finish))
                    Event(day, start, duration.coerceIn(0, 0xFFFF), false, tentative, color, title)
                }
            }
        }
        // ponytail: an event that began over 128 days ago would wrap its i8 day; dropped, they are rare
        return events.filter { it.day >= -128 }.sortedWith(compareBy({ it.day }, { !it.allDay }, { it.start }))
            .take(limit).map { calendarRecord(it, show) }
    }

    private fun ageMin(l: Location) = (SystemClock.elapsedRealtimeNanos() - l.elapsedRealtimeNanos) / 60_000_000_000L

    /** The last known fix, a fresh one when that is over 15 min old; the locality with it. */
    private suspend fun location(): Pair<Location, String> {
        val lm = context.getSystemService(LocationManager::class.java)
        val last = lastKnown(lm)
        val fresh = if (last != null && ageMin(last) < 15) null else withTimeoutOrNull(4000) {
            val provider = if (lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) LocationManager.NETWORK_PROVIDER
            else LocationManager.PASSIVE_PROVIDER
            suspendCancellableCoroutine<Location?> { k ->
                val cancel = CancellationSignal()
                k.invokeOnCancellation { cancel.cancel() }
                lm.getCurrentLocation(provider, cancel, context.mainExecutor) { k.resume(it) }
            }
        }
        val l = fresh ?: last ?: throw RpcError(RpcStatus.UNAVAILABLE)
        return l to place(l)
    }

    private fun lastKnown(lm: LocationManager): Location? =
        lm.getProviders(true).mapNotNull { lm.getLastKnownLocation(it) }.maxByOrNull { it.elapsedRealtimeNanos }

    /** Locality by 0.1° cell, cached; "" when the geocoder has none in time. */
    private suspend fun place(l: Location): String {
        val cell = "%.1f,%.1f".format(Locale.US, l.latitude, l.longitude)
        places[cell]?.let { return it }
        if (!Geocoder.isPresent()) return ""
        val g = Geocoder(context)
        val found = withTimeoutOrNull(2000) {
            if (Build.VERSION.SDK_INT >= 33) {
                suspendCancellableCoroutine { k ->
                    g.getFromLocation(l.latitude, l.longitude, 1, object : Geocoder.GeocodeListener {
                        override fun onGeocode(a: MutableList<android.location.Address>) = k.resume(a.firstOrNull())
                        override fun onError(message: String?) = k.resume(null)
                    })
                }
            } else {
                @Suppress("DEPRECATION")
                runCatching { g.getFromLocation(l.latitude, l.longitude, 1)?.firstOrNull() }.getOrNull()
            }
        } ?: return ""
        return (found.locality ?: found.subAdminArea ?: found.adminArea ?: "").also { places[cell] = it }
    }

    /** [zone]: the phone's when it was fetched, whose days the daily ranges cover. [located]: from a fresh fix, or one
     *  that was asked for. Otherwise only the card reuses it. */
    private class Forecast(val at: Long, val zone: java.time.ZoneId, val json: JSONObject, val located: Boolean)

    /** Weather's card from the same forecast, a stale copy when there's no new one; null with none. It never asks for
     *  a location fix: it runs in the background, so the last known one has to do. */
    suspend fun weatherCardRecord(): ByteArray? = try {
        val f = currentForecast(locate = false)
        val now = ZonedDateTime.now() // one for both, or they could fall on either side of an hour
        weatherCard(forecastRecords(f.json, f.at, now, days = 0, hours = 4), now.hour)
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    private suspend fun weather(days: Int, hours: Int): List<ByteArray> {
        val f = currentForecast(locate = true)
        return forecastRecords(f.json, f.at, ZonedDateTime.now(), days, hours)
    }

    /** Open-Meteo, cached 30 min; a stale copy when the network is down. */
    private suspend fun currentForecast(locate: Boolean): Forecast {
        val now = System.currentTimeMillis()
        val zone = java.time.ZoneId.systemDefault()
        return forecast?.takeIf { now - it.at < 30 * 60_000 && it.zone == zone && (it.located || !locate) }
            ?: runCatching { fetchForecast(now, zone, locate) }.getOrNull()?.also { forecast = it }
            ?: forecast ?: throw RpcError(RpcStatus.UNAVAILABLE)
    }

    // ponytail: one cached forecast for wherever the phone was; it follows a move after 30 min
    private suspend fun fetchForecast(now: Long, zone: java.time.ZoneId, locate: Boolean): Forecast {
        val l = if (locate) location().first
        else lastKnown(context.getSystemService(LocationManager::class.java)) ?: throw RpcError(RpcStatus.UNAVAILABLE)
        val (code, body) = fetch(forecastUrl(l.latitude, l.longitude, zone))
        if (code != 200) throw RpcError(RpcStatus.UNAVAILABLE)
        return Forecast(now, zone, JSONObject(String(body)), located = locate || ageMin(l) < 15)
    }

    private companion object {
        const val DAY_MS = 86_400_000L
        val places = java.util.concurrent.ConcurrentHashMap<String, String>()
        @Volatile var forecast: Forecast? = null
    }
}

/** Watch apps' key/value stores (storage, 0x60–0x62): app files Android doesn't back up. */
fun appStorage(context: Context) = KeyValueStore(java.io.File(context.noBackupFilesDir, "storage"))

/** The notifications shown now; the user turns it on in Android's notification access settings. */
class NotificationWatcher : NotificationListenerService() {
    override fun onListenerConnected() { live = this }
    override fun onListenerDisconnected() { live = null }

    companion object {
        @Volatile private var live: NotificationWatcher? = null

        /** Newest first, without ongoing ones, group summaries and the companion's own. */
        fun records(context: Context, limit: Int, show: Boolean): List<ByteArray> {
            val s = live ?: throw RpcError(RpcStatus.UNAVAILABLE)
            val pm = context.packageManager
            val now = System.currentTimeMillis()
            return (s.activeNotifications ?: emptyArray())
                .filter { !it.isOngoing && it.packageName != context.packageName && it.notification.flags and Notification.FLAG_GROUP_SUMMARY == 0 }
                .sortedByDescending { it.postTime }.take(limit).map { n ->
                    val app = runCatching { pm.getApplicationLabel(pm.getApplicationInfo(n.packageName, 0)).toString() }
                        .getOrDefault(n.packageName)
                    val e = n.notification.extras
                    val text = listOfNotNull(e.getCharSequence(Notification.EXTRA_TITLE), e.getCharSequence(Notification.EXTRA_TEXT))
                        .map { it.toString() }.filter { it.isNotEmpty() }.joinToString(": ")
                    notificationRecord((now - n.postTime) / 60_000, app, text, show)
                }
        }
    }
}
