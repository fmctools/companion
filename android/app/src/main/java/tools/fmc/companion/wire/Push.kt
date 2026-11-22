package tools.fmc.companion.wire

// PUSH (stub 8, cmf-watch-sdk docs/widget-push.md): the phone writes a watch app's widget card or start blob while
// the app doesn't run. Used for its background jobs (docs/miniapp-rpc.md, job.set) and, from stub 9, for Weather's
// columns card (WeatherCard.kt). Port of WireKit Push.swift.

/** What a PUSH writes: the widget card's record (64 bytes; from stub 9 also v2, up to 128), or the blob the app gets
 *  as its first message at start. */
object PushKind {
    const val WIDGET = 0
    const val BLOB = 1
}

sealed class PushResult {
    data object Ok : PushResult()
    /** Written less than 60 s ago; nothing written, retry after [ms]. */
    data class Later(val ms: Long) : PushResult()
    /** NoApp (7), BadRequest (1, also every stub before 8), Io (2); 0xFF for an empty reply. */
    data class Refused(val status: Int) : PushResult()
}

/** From stub 8 on; older stubs answer BadRequest. */
fun canPush(stub: Long) = stub >= 8

/** title ≤ 23 bytes at 0, value ≤ 39 bytes at 24 (0A starts a second line), NUL-padded to 64. */
fun widgetRecord(title: String, value: String): ByteArray = utf8Cut(title, 23).copyOf(24) + utf8Cut(value, 39).copyOf(40)

/** One column of a v2 `columns` record. [icon] indexes the package's widget icons, null none. */
data class WidgetColumn(val caption: String, val icon: Int?, val value: String)

/** From stub 9 on: v2 records. An older stub answers BadRequest. */
fun canPushColumns(stub: Long) = stub >= 9

/** The v2 record the stub draws as columns: `FF 01 n`, then per column `caption[10] ‖ icon:u8 ‖ value[10]`
 *  (install.columns_record). null for other than 1..4 columns or an icon outside 0..15. */
fun columnsRecord(columns: List<WidgetColumn>): ByteArray? {
    if (columns.size !in 1..4 || columns.any { it.icon != null && it.icon !in 0..15 }) return null
    return buf {
        u8(0xFF); u8(1); u8(columns.size)
        for (c in columns) { add(utf8Cut(c.caption, 9).copyOf(10)); u8(c.icon ?: 0xFF); add(utf8Cut(c.value, 9).copyOf(10)) }
    }
}

fun pushPayload(slot: Int, kind: Int, data: ByteArray): ByteArray = bytes(slot, kind) + data

fun parsePushReply(r: ByteArray): PushResult = when {
    r.isEmpty() -> PushResult.Refused(0xFF)
    r.u8(0) == Status.OK.code -> PushResult.Ok
    r.u8(0) == 0x0A && r.size >= 5 -> PushResult.Later(r.le32(1))
    else -> PushResult.Refused(r.u8(0))
}

/** PUSH on a session; empty [data] removes the record. */
suspend fun push(s: Requester, slot: Int, kind: Int, data: ByteArray): PushResult =
    parsePushReply(s.call(Cmd.PUSH, pushPayload(slot, kind, data)))

/** A job's start blob: each record as `len:u8 ‖ record`, whole records while they fit 128 bytes; null when none does. */
fun jobBlob(records: List<ByteArray>): ByteArray? {
    var out = ByteArray(0)
    for (r in records) {
        if (out.size + 1 + r.size > 128) break
        out += bytes(r.size) + r
    }
    return out.takeIf { it.isNotEmpty() }
}

/** A web job's widget: a 2xx body as UTF-8, its first line the title, the rest the value; null for anything else. */
fun jobWidget(records: List<ByteArray>): ByteArray? {
    val head = records.firstOrNull()?.takeIf { it.size >= 4 && it.le16(0) in 200..299 } ?: return null
    val body = records.drop(1).fold(ByteArray(0)) { a, b -> a + b }
    val text = runCatching { Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(body)).toString() }.getOrNull() ?: return null
    val lines = text.split("\n", limit = 2)
    return widgetRecord(lines[0], lines.getOrElse(1) { "" })
}
