package tools.fmc.companion

import java.net.URLEncoder
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit
import java.util.Locale
import org.json.JSONObject
import tools.fmc.companion.wire.WeatherHour
import tools.fmc.companion.wire.currentHours
import tools.fmc.companion.wire.weatherDay
import tools.fmc.companion.wire.weatherHours
import tools.fmc.companion.wire.weatherNow

// Open-Meteo for the `weather` service: the request, and its answer as the RPC's records. Hours and days are the
// phone's, whatever the timezone of the coordinates: that one isn't sent to the watch.

/** [zone] the phone's, so the hours are its hours and a day's range covers its day. Times come as instants: local
 *  ones use one UTC offset for the whole answer and don't tell the repeated hour of a clock change apart. */
internal fun forecastUrl(lat: Double, lon: Double, zone: ZoneId): String =
    "https://api.open-meteo.com/v1/forecast?latitude=%.2f&longitude=%.2f".format(Locale.US, lat, lon) +
        "&current=temperature_2m,weather_code,wind_speed_10m,relative_humidity_2m" +
        "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max" +
        "&hourly=temperature_2m,weather_code,precipitation_probability,is_day&forecast_hours=26" +
        "&wind_speed_unit=ms&forecast_days=8&timeformat=unixtime" +
        // the API takes names and GMT+05:30, not a bare +05:30 or Z
        "&timezone=" + URLEncoder.encode(if (zone is ZoneOffset) "GMT" + zone.id.removePrefix("Z") else zone.id, "UTF-8")

/** `weather`'s records of an answer fetched at [fetchedAt] (ms), as of [now] on the phone's clock. */
internal fun forecastRecords(json: JSONObject, fetchedAt: Long, now: ZonedDateTime, days: Int, hours: Int): List<ByteArray> {
    val cur = json.getJSONObject("current")
    val out = mutableListOf(weatherNow(cur.getDouble("temperature_2m"), cur.getInt("weather_code"),
        cur.getDouble("wind_speed_10m"), cur.getInt("relative_humidity_2m"), (now.toInstant().toEpochMilli() - fetchedAt) / 60_000))
    json.optJSONObject("hourly")?.let { h ->
        val times = h.getJSONArray("time")
        val all = (0 until times.length()).map {
            Instant.ofEpochSecond(times.getLong(it)) to WeatherHour(
                h.getJSONArray("temperature_2m").getDouble(it), h.getJSONArray("weather_code").getInt(it),
                h.getJSONArray("precipitation_probability").optInt(it, 0), h.getJSONArray("is_day").optInt(it, 1) == 0)
        }
        val (hour, list) = currentHours(all, now)
        weatherHours(hour, list, hours)?.let { out += it }
    }
    val d = json.getJSONObject("daily")
    val today = now.toLocalDate()
    val dates = d.getJSONArray("time")
    for (i in 0 until dates.length()) {
        // a day's middle, not its start: past a clock change the start is 23:00 of the day before
        val date = Instant.ofEpochSecond(dates.getLong(i)).plus(Duration.ofHours(12)).atZone(now.zone).toLocalDate()
        val day = ChronoUnit.DAYS.between(today, date).toInt()
        if (day !in 0 until days) continue
        out += weatherDay(day, d.getJSONArray("temperature_2m_min").getDouble(i), d.getJSONArray("temperature_2m_max").getDouble(i),
            d.getJSONArray("weather_code").getInt(i), d.getJSONArray("precipitation_probability_max").optInt(i, 0))
    }
    return out
}
