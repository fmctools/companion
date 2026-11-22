package tools.fmc.companion.wire

import kotlin.test.Test
import kotlin.test.assertEquals

/** face-gate-vectors.json, as ios/WireKit GateTests.swift. */
class GateTest {
    @Test fun failsClosedAsTheSite() {
        val faces = Vectors.gate.getJSONArray("faces")
        val wrong = mutableListOf<String>()
        for (i in 0 until faces.length()) {
            val f = faces.getJSONObject(i)
            val want = f.getJSONObject("refuse")
            for (device in want.keys()) {
                val verdict = checkFace(hex(f.getString("hex")), device == "watch_3_pro")
                if ((verdict is FaceVerdict.Refuse) != want.getBoolean(device)) wrong += "${f.getString("name")} $device: $verdict"
            }
        }
        assertEquals(emptyList(), wrong)
    }
}
