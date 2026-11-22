package tools.fmc.companion.wire

// Installing an app package from the phone over K (src/wp2apps/install.py): INFO, BEGIN, DATA…, END.
// Port of ios/WireKit Install.swift.

const val LOADER_SLOT = 0xFF

/** App slots on the watch, 0..n-1: 8 before stub 8, 16 from stub 8 (cmf-watch-sdk docs/app-order.md, "The table";
 *  stub 7 on cmf-watch-sdk main is another change). */
fun appSlots(stub: Long): Int = if (stub >= 8) 16 else 8

/** The stub's release from INFO on 0xFE; 1 when the reply doesn't say. */
suspend fun stubVersion(s: Requester): Long = parseStubReply(s.call(Cmd.INFO, bytes(STUB_SLOT)))?.version ?: 1
private const val HEADER_SIZE = 64
private const val DATA_MAX = 128

/** `crc`: CRC-32 of the image, tells two builds with the same version apart (the loader's version stays 1). */
data class PackageHeader(val kind: Int, val name: String, val version: Long, val crc: Long = 0)

sealed class InstallError(message: String) : Exception(message) {
    data object Busy : InstallError("the app is running on the watch")
    /** Every one of the watch's [slots] app slots holds another app. */
    data class NoFreeSlot(val slots: Int) : InstallError("all $slots app slots on the watch are taken")
    data object NotAPackage : InstallError("not an app package")
    data class Refused(val status: Int) : InstallError("refused (%02X)".format(status))
}

/** The first stub that takes a package's widget icon trailer ("WP2W", cmf-watch-sdk docs/app-icons.md). */
private const val TRAILER_STUB = 9

/** The package without its widget icon trailer, the same bytes as one packed without icons: body_crc doesn't cover
 *  the trailer (package.strip_trailer). An older stub refuses any byte past what the header says. */
internal fun stripTrailer(p: ByteArray): ByteArray {
    if (p.size < HEADER_SIZE) return p
    val end = HEADER_SIZE + p.le32(36) + 4 * p.le32(44)
    return if (end < p.size) p.copyOf(end.toInt()) else p
}

/** The package header (`package.HEADER`: magic "WP2A", abi, kind, abi_minor, name[24], version, size, entry,
 * relocations, crc, …). */
fun parseHeader(d: ByteArray): PackageHeader? {
    if (d.size < HEADER_SIZE || !d.copyOf(4).contentEquals("WP2A".toByteArray())) return null
    val name = d.copyOfRange(8, 32).takeWhile { it != 0.toByte() }.toByteArray()
    return PackageHeader(d.u8(6), String(name), d.le32(32), d.le32(48))
}

private fun check(r: ByteArray): ByteArray {
    if (r.isEmpty()) throw InstallError.Refused(0xFF)
    if (r.u8(0) == Status.BUSY.code) throw InstallError.Busy
    if (r.u8(0) != Status.OK.code) throw InstallError.Refused(r.u8(0))
    return r.copyOfRange(1, r.size)
}

/** Headers of the occupied slots (0 until [slots] and the loader). */
suspend fun installed(s: Requester, slots: Int): Map<Int, PackageHeader> {
    val out = sortedMapOf<Int, PackageHeader>()
    for (slot in (0 until slots) + LOADER_SLOT) {
        parseHeader(check(s.call(Cmd.INFO, bytes(slot))))?.let { out[slot] = it }
    }
    return out
}

/**
 * Installs an app package into the slot of the same name, else the first free one, and a loader package (kind 1)
 * into slot L; returns the slot. `Busy` while that app (or the loader's menu) runs on the watch.
 * An app's widget icon trailer goes to stub 9 as it is (the stub checks it and drops a broken one); an older stub
 * gets the package without it.
 */
suspend fun install(s: Requester, pkg: ByteArray, progress: (Double) -> Unit): Int {
    val header = parseHeader(pkg)?.takeIf { it.kind == 0 || it.kind == 1 } ?: throw InstallError.NotAPackage
    var file = pkg
    val slot = if (header.kind == 1) LOADER_SLOT else {
        val stub = stubVersion(s)
        if (stub < TRAILER_STUB) file = stripTrailer(pkg)
        val slots = appSlots(stub)
        val used = installed(s, slots)
        used.entries.firstOrNull { it.key < slots && it.value.name == header.name }?.key
            ?: (0 until slots).firstOrNull { it !in used }
            ?: throw InstallError.NoFreeSlot(slots)
    }
    check(s.call(Cmd.BEGIN, buf { u8(slot); le32(file.size.toLong()); le32(crc32(file)) }))
    for (off in file.indices step DATA_MAX) {
        val end = minOf(off + DATA_MAX, file.size)
        val r = check(s.call(Cmd.DATA, buf { le32(off.toLong()); add(file.copyOfRange(off, end)) }))
        if (r.size != 4 || r.le32(0) != end.toLong()) throw InstallError.Refused(0xFE)
        progress(end.toDouble() / file.size)
    }
    check(s.call(Cmd.END, bytes(0)))
    return slot
}

/** Removes the app in [slot] with its data (stub DELETE). [InstallError.Busy] while that app runs on the watch. */
suspend fun remove(s: Requester, slot: Int) {
    check(s.call(Cmd.DELETE, bytes(slot)))
}

// Apps menu order (cmf-watch-sdk docs/app-order.md)

/** No single WP2ORDER table in the image (a loader older than the app order), over 16 names, or a name not 1..23
 *  UTF-8 bytes. */
class OrderError(message: String) : Exception(message)

/**
 * The loader package with the Apps menu order [names] (package names, first row first) in its WP2ORDER table,
 * re-signed: the image CRC at 0x30, then the header CRC at 0x34. Install it to slot 0xFF like any loader.
 */
fun setOrder(pkg: ByteArray, names: List<String>): ByteArray {
    val magic = "WP2ORDER".toByteArray()
    val fields = 16
    val field = 24
    val encoded = names.map { it.toByteArray() }
    if (encoded.size > fields || encoded.any { it.size !in 1..23 }) throw OrderError("at most 16 names of 1..23 bytes")
    val hits = (HEADER_SIZE..pkg.size - magic.size).filter { i -> (magic.indices).all { pkg[i + it] == magic[it] } }
    if (hits.size != 1 || hits[0] + magic.size + fields * field > pkg.size) throw OrderError("no WP2ORDER table in the loader")
    val p = pkg.copyOf()
    val t = hits[0] + magic.size
    ByteArray(fields * field).also { table -> encoded.forEachIndexed { i, n -> n.copyInto(table, i * field) } }.copyInto(p, t)
    fun put(v: Long, at: Int) { for (k in 0..3) p[at + k] = (v shr (8 * k)).toByte() }
    put(crc32(p.copyOfRange(HEADER_SIZE, p.size)), 0x30)
    put(crc32(p.copyOfRange(0, 0x34)), 0x34)
    return p
}
