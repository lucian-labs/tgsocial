package ca.lucianlabs.tgsocial.demo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * PRODUCT §2.22.1 — a plate is "a linear gradient between two House Pour tokens chosen by the seed".
 *
 * The word doing the work is *tokens*. A palette invented at the demo layer looks like House Pour and is not
 * House Pour: it does not move when `design/tokens.json` moves, and iOS and web, reading the same sentence,
 * invent their own — so the one fixture world becomes three that merely resemble each other. This reads the
 * kit's own source of truth off disk and holds the plates to it, which is the only version of this assertion
 * that a retyped hex cannot pass.
 */
class DemoPlateTest {

    /** Every colour `design/tokens.json` declares, as opaque ARGB — the set a plate may draw from. */
    private val tokenColors: Set<Int> by lazy {
        val json = File(repoRoot(), "design/tokens.json").readText()
        val block = json.substringAfter("\"color\": {").substringBefore("\n  }")
        val hex = Regex("\"#([0-9a-fA-F]{6})\"").findAll(block).map { 0xFF000000.toInt() or it.groupValues[1].toInt(16) }
        val rgba = Regex("rgba\\((\\d+), *(\\d+), *(\\d+)").findAll(block).map { m ->
            val (r, g, b) = m.destructured
            0xFF000000.toInt() or (r.toInt() shl 16) or (g.toInt() shl 8) or b.toInt()
        }
        (hex + rgba).toSet().also { assertTrue("no colours parsed out of tokens.json", it.size > 10) }
    }

    /** The colours the generator actually reaches for, sampled across the key space rather than asserted by name. */
    private val used: Set<Int> by lazy {
        val out = HashSet<Int>()
        for (channel in listOf("demo_tidewright", "demo_kiln_log", "demo_slow_radio", "demo_press_run", "demo_wren_bench", "demo_creek_cam")) {
            for (id in 1..120) {
                val (a, b) = DemoMedia.plateColors("$channel/$id·1")
                out += a
                out += b
            }
        }
        out
    }

    @Test
    fun `every plate colour is a colour design tokens declares`() {
        val strays = used.filterNot { it in tokenColors }
        if (strays.isNotEmpty()) {
            fail("plates draw colours that are not in design/tokens.json: " + strays.joinToString { String.format("#%06x", it and 0xFFFFFF) })
        }
    }

    @Test
    fun `the palette is the seven the generator declares, not one colour repeated`() {
        assertEquals(used.toString(), 7, used.size)
    }

    private fun repoRoot(): File {
        var dir: File? = File(System.getProperty("user.dir").orEmpty())
        while (dir != null) {
            if (File(dir, "design/tokens.json").isFile) return dir
            dir = dir.parentFile
        }
        fail("could not find design/tokens.json")
        error("unreachable")
    }
}
