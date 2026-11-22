package tools.fmc.companion

import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.json.JSONArray
import org.json.JSONObject
import tools.fmc.companion.wire.u8

/** The forecast's hours and days are the phone's, whatever the timezone of the coordinates. */
class OpenMeteoTest {
    private val losAngeles = ZoneId.of("America/Los_Angeles")
    private val newYork = ZoneId.of("America/New_York")
    private val tokyo = ZoneId.of("Asia/Tokyo")
    private val kolkata = ZoneId.of("Asia/Kolkata")
    private val london = ZoneId.of("Europe/London")

    /**
     * What Open-Meteo answers [url] at [at] for coordinates in [place], as seen from the API on 2026-11-22: `timezone`
     * picks the hours and days (`auto`: the place's), `timeformat=unixtime` gives instants instead of local times, and
     * the whole answer uses one UTC offset, today's. An hour's temperature is its distance from now, a day's
     * minimum its day of the month, night follows the place's clock.
     */
    private fun api(url: String, place: ZoneId, at: Instant): JSONObject {
        val q = url.toHttpUrl()
        val zone = q.queryParameter("timezone")!!.let { if (it == "auto") place else ZoneId.of(it) }
        val offset = zone.rules.getOffset(at)
        val unix = q.queryParameter("timeformat") == "unixtime"
        val local = at.atOffset(offset).toLocalDateTime()
        val hours = (0 until 26).map { local.truncatedTo(ChronoUnit.HOURS).plusHours(it.toLong()) }
        val dates = (0 until 8).map { local.toLocalDate().plusDays(it.toLong()) }
        val hourly = JSONObject()
            .put("time", JSONArray(hours.map { if (unix) it.toEpochSecond(offset) else it.toString() }))
            .put("temperature_2m", JSONArray(hours.indices.toList()))
            .put("weather_code", JSONArray(hours.map { 3 }))
            .put("precipitation_probability", JSONArray(hours.map { 0 }))
            .put("is_day", JSONArray(hours.map { if (it.toInstant(offset).atZone(place).hour in 7..18) 1 else 0 }))
        val daily = JSONObject()
            .put("time", JSONArray(dates.map { if (unix) it.atStartOfDay().toEpochSecond(offset) else it.toString() }))
            .put("temperature_2m_min", JSONArray(dates.map { it.dayOfMonth }))
            .put("temperature_2m_max", JSONArray(dates.map { it.dayOfMonth + 1 }))
            .put("weather_code", JSONArray(dates.map { 3 }))
            .put("precipitation_probability_max", JSONArray(dates.map { 0 }))
        val current = JSONObject().put("temperature_2m", 5).put("weather_code", 3)
            .put("wind_speed_10m", 2).put("relative_humidity_2m", 50)
        return JSONObject().put("timezone", zone.id).put("current", current).put("hourly", hourly).put("daily", daily)
    }

    private class Seen(val records: List<ByteArray>) {
        private val h = records.firstOrNull { it.u8(0) == 2 }
        val hour = h?.u8(1)
        val temps = h?.let { r -> (2 until r.size step 3).map { r[it].toInt() } }.orEmpty()
        val nights = h?.let { r -> (4 until r.size step 3).map { r.u8(it) and 0x80 != 0 } }.orEmpty()
        /** day from today to that day's minimum. */
        val days = records.filter { it.u8(0) == 1 }.map { it[1].toInt() to it[2].toInt() }
    }

    private fun seen(phone: ZoneId, place: ZoneId, fetched: String, now: String = fetched, phoneNow: ZoneId = phone): Seen {
        val at = Instant.parse(fetched)
        val json = api(forecastUrl(35.68, 139.69, phone), place, at)
        return Seen(forecastRecords(json, at.toEpochMilli(), Instant.parse(now).atZone(phoneNow), days = 7, hours = 12))
    }

    private fun assertOnPhonesClock(phone: ZoneId, place: ZoneId, at: String) {
        val s = seen(phone, place, at)
        val now = Instant.parse(at).atZone(phone)
        val what = "phone $phone, place $place, $at"
        assertEquals(now.hour, s.hour, what)
        assertEquals((0 until 12).toList(), s.temps, "$what: the first hour is the one that contains now")
        assertEquals((0 until 7).map { it to now.toLocalDate().plusDays(it.toLong()).dayOfMonth }, s.days, what)
    }

    @Test fun sameZone() = assertOnPhonesClock(tokyo, tokyo, "2026-11-22T03:20:00Z")

    @Test fun placeAheadOfThePhone() = assertOnPhonesClock(losAngeles, tokyo, "2026-11-22T19:15:00Z")

    @Test fun placeBehindThePhone() = assertOnPhonesClock(tokyo, losAngeles, "2026-11-22T19:15:00Z")

    @Test fun threeHoursApartAroundMidnight() {
        assertOnPhonesClock(losAngeles, newYork, "2026-11-23T06:30:00Z") // 22:30 and 01:30 the next day
        assertOnPhonesClock(newYork, losAngeles, "2026-11-23T06:30:00Z")
    }

    @Test fun halfHourZone() {
        assertOnPhonesClock(kolkata, london, "2026-11-22T19:15:00Z")
        assertOnPhonesClock(london, kolkata, "2026-11-22T19:15:00Z")
    }

    @Test fun daysAcrossTheClockChange() {
        assertOnPhonesClock(losAngeles, losAngeles, "2026-10-30T19:15:00Z") // back on 1 November
        assertOnPhonesClock(losAngeles, losAngeles, "2027-03-11T19:15:00Z") // forward on 14 March
        assertOnPhonesClock(losAngeles, tokyo, "2026-10-30T19:15:00Z")
    }

    @Test fun theRepeatedHour() {
        val s = seen(newYork, newYork, "2026-11-01T05:10:00Z", now = "2026-11-01T06:10:00Z") // 01:10 EDT, then 01:10 EST
        assertEquals(1, s.hour)
        assertEquals((1..12).toList(), s.temps, "the first 01:00 has passed")
    }

    @Test fun staleCopyCountsFromThePhonesClock() {
        val s = seen(losAngeles, tokyo, "2026-11-22T19:15:00Z", now = "2026-11-22T22:40:00Z")
        assertEquals(14, s.hour)
        assertEquals((3..14).toList(), s.temps)
    }

    @Test fun staleCopyAfterThePhoneChangedItsZone() {
        val s = seen(losAngeles, tokyo, "2026-11-22T19:15:00Z", now = "2026-11-22T20:20:00Z", phoneNow = newYork)
        assertEquals(15, s.hour)
        assertEquals((1..12).toList(), s.temps)
    }

    @Test fun anOffsetWithoutANameStillCountsOnThePhonesClock() {
        assertOnPhonesClock(java.time.ZoneOffset.ofHours(-5), tokyo, "2026-11-22T19:15:00Z")
        assertOnPhonesClock(java.time.ZoneOffset.UTC, tokyo, "2026-11-22T19:15:00Z")
    }

    @Test fun nightIsThePlaces() {
        val s = seen(losAngeles, tokyo, "2026-11-22T19:15:00Z") // 04:15 in Tokyo
        assertEquals(listOf(true, true, true, false), s.nights.take(4))
    }
}
