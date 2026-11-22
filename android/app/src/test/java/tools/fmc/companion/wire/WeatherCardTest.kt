package tools.fmc.companion.wire

import java.time.LocalDateTime
import java.time.ZoneOffset
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Weather's card (docs/miniapp-rpc.md, "Weather's card"): push-vectors.json, shared with iOS. */
class WeatherCardTest {
    @Test fun cardFromForecast() {
        val cards = Vectors.push.getJSONArray("weather_cards")
        for (k in 0 until cards.length()) {
            val c = cards.getJSONObject(k)
            val start = LocalDateTime.parse(c.getString("start")).toInstant(ZoneOffset.UTC)
            val hours = c.getJSONArray("hours")
            val forecast = (0 until hours.length()).map {
                val h = hours.getJSONArray(it)
                // 100 shares its byte with night
                start.plusSeconds(it * 3600L) to WeatherHour(h.getDouble(0), h.getInt(1), 100, h.length() > 2)
            }
            val records = mutableListOf<ByteArray>()
            c.optJSONArray("now")?.let { records += weatherNow(it.getDouble(0), it.getInt(1), 0.0, 0, 0) }
            val at = LocalDateTime.parse(c.getString("at"))
            val (hour, current) = currentHours(forecast, at.atZone(ZoneOffset.UTC))
            weatherHours(hour, current, 4)?.let { records += it }
            assertEquals(if (c.isNull("hex")) null else c.getString("hex"), weatherCard(records, at.hour)?.hex(), c.getString("note"))
        }
    }

    @Test fun icons() {
        val icons = Vectors.push.getJSONArray("weather_icons")
        for (k in 0 until icons.length()) icons.getJSONArray(k).let {
            assertEquals(it.getInt(1), weatherIcon(it.getInt(0), night = false), "WMO ${it.getInt(0)}")
            assertEquals(it.getInt(2), weatherIcon(it.getInt(0), night = true), "WMO ${it.getInt(0)} at night")
        }
    }

    @Test fun gate() {
        val apps = mapOf(0 to "hello", 15 to "weather")
        assertEquals(15, weatherCardSlot(9, apps, true))
        assertNull(weatherCardSlot(8, apps, true), "stub 8: no card, and no v1 in its place")
        assertNull(weatherCardSlot(9, apps, false))
        assertNull(weatherCardSlot(9, mapOf(0 to "hello", 1 to "weather2"), true))
        assertNull(weatherCardSlot(9, mapOf(16 to "weather", 0xFF to "weather"), true), "slots 0..15 only")
    }

    @Test fun schedule() {
        val t = 1_795_000_000_000L
        val two = t + 3_600_000
        val three = t + 7_200_000
        val a = bytes(1)
        val b = bytes(2)
        val s = CardSchedule()
        assertTrue(s.due(t, t), "on connect")
        s.settle(PushResult.Ok, a, t, t)
        assertFalse(s.due(t, t + 300_000), "once an hour")
        assertFalse(s.due(two, t + 59_999), "the stub takes one write per 60 s")
        assertTrue(s.due(two, t + 60_000))
        val same = CardSchedule().apply { settle(PushResult.Ok, a, t, t) }
        assertTrue(same.unchanged(a, two) && !same.due(two, t + 600_000), "the same bytes: no repeat")
        assertTrue(!s.unchanged(b, two) && s.due(two, t + 60_000))
        s.settle(PushResult.Later(7000), b, two, t + 60_000)
        assertTrue(!s.due(two, t + 66_999) && s.due(two, t + 67_000), "Later: after the wait it names")
        assertFalse(s.unchanged(b, two), "Later wrote nothing")
        s.settle(null, null, two, t + 67_000)
        assertTrue(!s.due(three, t + 366_999) && s.due(three, t + 367_000), "no card: again in 5 min")
        s.settle(PushResult.Refused(7), b, three, t + 367_000)
        assertTrue(!s.unchanged(b, three) && !s.due(three, t + 666_999) && s.due(three, t + 667_000))
        assertTrue(CardSchedule().due(t, t), "a new session sends again")
    }
}
