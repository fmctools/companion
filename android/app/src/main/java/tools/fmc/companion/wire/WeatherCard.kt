package tools.fmc.companion.wire

import java.time.Instant
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit

// Weather's widget card, kept fresh by the phone (stub 9, docs/miniapp-rpc.md "Weather's card"): now and the next three
// hours as a v2 `columns` record, the same bytes the Weather app writes from the same answer. It is built from the
// `weather` RPC's own records, so both sides round, clamp and count the hours alike. Port of WireKit WeatherCard.swift.

/** The store's package that gets the card. */
const val WEATHER_PACKAGE = "weather"

/** A forecast's hours from the one that contains [now], counted on the phone's clock (a cached copy may start hours
 *  back), and the first one's own hour (0–23), so one that only starts after this hour doesn't pass for it. An empty
 *  list when every hour of it has passed. */
fun currentHours(forecast: List<Pair<Instant, WeatherHour>>, now: ZonedDateTime): Pair<Int, List<WeatherHour>> {
    val thisHour = now.truncatedTo(ChronoUnit.HOURS) // keeps the offset, so the repeated hour of a clock change counts once
    val from = thisHour.toInstant()
    val left = forecast.filter { !it.first.isBefore(from) }
    val hour = left.firstOrNull()?.first?.atZone(now.zone)?.hour ?: thisHour.hour
    return hour to left.map { it.second }
}

/** The icon's index in Weather's package: its `model::Icon` order (clear, partly, cloud, fog, drizzle, rain, snow,
 *  storm), then clear (8) and partly (9) at night. A contract with that package: append only. */
internal fun weatherIcon(code: Int, night: Boolean): Int = when (code) {
    0 -> if (night) 8 else 0
    1, 2 -> if (night) 9 else 1
    45, 48 -> 3
    in 51..57 -> 4
    in 61..67, in 80..82 -> 5
    in 71..77, 85, 86 -> 6
    in 95..99 -> 7
    else -> 2
}

/** Now, then the next three hours after the one that contains now (fewer when fewer are known), from the records
 *  `weather` answers at [hour] (0–23) of the phone's clock. Night is only what an hourly entry's bit says; for Now
 *  that of the entry that contains now, day without one. null without the current record: then the phone writes
 *  nothing. */
fun weatherCard(records: List<ByteArray>, hour: Int): ByteArray? {
    val now = records.firstOrNull { it.size >= 4 && it.u8(0) == 0 } ?: return null
    val tenths = now.le16(1).toShort().toInt()
    val degrees = if (tenths >= 0) (tenths + 5) / 10 else -((5 - tenths) / 10) // halves away from zero, never "-0"
    val next = mutableListOf<WidgetColumn>()
    var nightNow = false
    records.firstOrNull { it.size >= 5 && it.u8(0) == 2 }?.let { h ->
        // how far entry 0 is ahead of the hour that contains now: 0 unless the forecast only starts later
        val ahead = (h.u8(1) - hour + 24) % 24
        val count = (h.size - 2) / 3
        nightNow = ahead == 0 && h.u8(4) and 0x80 != 0
        for (later in 1..3) {
            val i = later - ahead
            if (i !in 0 until count) continue
            val at = 2 + 3 * i
            // not String.format: some locales have digits of their own
            val caption = "${((h.u8(1) + i) % 24).toString().padStart(2, '0')}:00"
            val night = h.u8(at + 2) and 0x80 != 0
            next += WidgetColumn(caption, weatherIcon(h.u8(at + 1), night), "${h[at].toInt()}°")
        }
    }
    return columnsRecord(listOf(WidgetColumn("Now", weatherIcon(now.u8(3), nightNow), "$degrees°")) + next)
}

/** Weather's slot when the phone may push its card: stub 9 or later, the app on the watch by its package name and
 *  holding the weather grant. Never a v1 card to an older stub: it would replace the app's own. */
fun weatherCardSlot(stub: Long, apps: Map<Int, String>, granted: Boolean): Int? {
    if (!granted || !canPushColumns(stub)) return null
    return apps.filter { it.key in 0 until appSlots(stub) && it.value == WEATHER_PACKAGE }.keys.minOrNull()
}

/** When one session sends the card: once it opens, then when the hour changes. The same bytes are not sent again,
 *  and a write waits out the stub's one per 60 s. Times are milliseconds. */
class CardSchedule {
    private var hour: Long? = null
    private var sent: ByteArray? = null
    private var wait: Long? = null

    /** [hour]: the start of the hour that contains [now]. */
    fun due(hour: Long, now: Long) = hour != this.hour && wait.let { it == null || now >= it }

    /** true: [card] is what this session wrote last, so this hour is done without a request. */
    fun unchanged(card: ByteArray, hour: Long): Boolean {
        if (!card.contentEquals(sent)) return false
        this.hour = hour
        return true
    }

    /** What became of the attempt; [result] null: no card or no answer, tried again in 5 min. */
    fun settle(result: PushResult?, card: ByteArray?, hour: Long, now: Long) {
        wait = now + when (result) {
            PushResult.Ok -> {
                this.hour = hour
                sent = card
                60_000L
            }
            is PushResult.Later -> result.ms
            is PushResult.Refused, null -> 300_000L
        }
    }
}
