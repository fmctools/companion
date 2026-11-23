package tools.fmc.companion.wire

import java.io.File
import org.json.JSONObject

/**
 * The files iOS tests run, read in place (ios/WireKit/Tests/WireKitTests): vectors.json is byte-for-byte the Python
 * host's (tests/ios_vectors.py), watchface-vectors.json is made by tools/watchface-vectors.ts from the site's code.
 */
object Vectors {
    private fun load(name: String) = JSONObject(File(System.getProperty("vectors"), name).readText())
    val k: JSONObject by lazy { load("vectors.json") }
    val face: JSONObject by lazy { load("watchface-vectors.json") }
    /** Made by tools/ota-vectors.ts from the site's inspectOtaImage and Watch.flashFirmware. */
    val ota: JSONObject by lazy { load("ota-vectors.json") }
    /** Made by tools/face-fit-vectors.ts from the site's budget.ts, fit.ts, etc2.ts and bin.ts. */
    val fit: JSONObject by lazy { load("face-fit-vectors.json") }
    /** Made by tools/push-vectors.py with the SDK's widget_record, columns_record and packer. */
    val push: JSONObject by lazy { load("push-vectors.json") }
    /** Made by tools/face-gate-vectors.ts from the site's assertFlashable. */
    val gate: JSONObject by lazy { load("face-gate-vectors.json") }
    /** Made by tools/rescue-vectors.ts from the site's Watch.authenticate, Watch.pair and Watch.factoryReset. */
    val rescue: JSONObject by lazy { load("rescue-vectors.json") }

    val pkg get() = k.getJSONObject("package")
    /** INFO's reply for a slot holding the vector package, without the status byte. */
    val header: ByteArray get() = hex(pkg.getString("info_reply_hex")).let { it.copyOfRange(1, it.size) }
    /** crc: crc32 of what follows the header, as package.pack writes it. */
    val pkgHeader get() = PackageHeader(pkg.getInt("kind"), pkg.getString("name"), pkg.getLong("version"),
        hex(pkg.getString("hex")).let { crc32(it.copyOfRange(64, it.size)) })
}
