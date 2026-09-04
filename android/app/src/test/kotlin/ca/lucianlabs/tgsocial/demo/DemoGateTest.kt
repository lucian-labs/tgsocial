package ca.lucianlabs.tgsocial.demo

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * PRODUCT §2.22.3 — `Open in Telegram`, `Copy Link`, `Share` and every link answer with one of three lines and
 * do nothing else.
 *
 * The last two tests are the load-bearing ones. Asserting that [DemoGate] returns true when it is open proves
 * nothing about the app; what matters is that **every function that leaves the app passes through it with the
 * right sentence**, and that every control reaches the function whose sentence is its own — so a kebab item
 * added next month is refused, and refused with the line §2.22.3 gives it.
 */
class DemoGateTest {

    @After
    fun close() = DemoGate.close()

    @Test
    fun `a closed gate refuses nothing and says nothing`() {
        DemoGate.close()
        var said: String? = null
        DemoGate.open { said = it }
        DemoGate.close()
        assertFalse(DemoGate.refused(DemoCopy.NO_LINKS))
        assertNull(said)
        assertFalse(DemoGate.isActive)
    }

    @Test
    fun `an open gate swallows the action and names the truth that applies`() {
        val said = ArrayList<String>()
        DemoGate.open { said += it }
        assertTrue(DemoGate.isActive)
        assertTrue(DemoGate.refused(DemoCopy.NOT_ON_TELEGRAM))
        assertTrue(DemoGate.refused(DemoCopy.NO_LINKS))
        assertEquals(listOf(DemoCopy.NOT_ON_TELEGRAM, DemoCopy.NO_LINKS), said)
    }

    /**
     * Every route out of the app is one of these functions, and each passes the one string §2.22.3 gives it.
     * Asserting only that a function asks the gate is what let `Open in Telegram` answer `Links don't open in
     * the demo.` for six controls: it asked, and it asked with the wrong sentence.
     */
    @Test
    fun `every route out of the app asks the gate, with the string that names its own truth`() {
        val links = source("ui/components/Links.kt")
        val expected = mapOf(
            // A link, a link preview, or a t.me link in post text.
            "fun openLink" to "DemoCopy.NO_LINKS",
            // `Open in Telegram`, `Copy Link`, `Share` — the item itself is not on Telegram.
            "fun openInTelegram" to "DemoCopy.NOT_ON_TELEGRAM",
            "fun shareLink" to "DemoCopy.NOT_ON_TELEGRAM",
            "fun copyToClipboard" to "DemoCopy.NOT_ON_TELEGRAM",
        )
        for ((fn, constant) in expected) {
            val body = links.substringAfter(fn).substringBefore("\n}\n")
            assertTrue("$fn does not ask DemoGate", body.contains("DemoGate.refused("))
            assertTrue("$fn refuses with something other than $constant", body.contains("DemoGate.refused($constant)"))
        }
        // §2.22.2 keeps report working in full, and the composer is the reader's own mail client: the app
        // hands it a `mailto:` and makes no request itself. So this one is deliberately NOT gated.
        val mail = links.substringAfter("fun openMail").substringBefore("\n}\n")
        assertFalse("the report email must survive the demo", mail.contains("DemoGate.refused("))
    }

    /**
     * The other half of the same defect: a control can carry the right words and call the wrong function.
     * Every `Open in Telegram` in the tree must reach [openInTelegram] — the one that answers
     * `Nothing here is on Telegram.` — and none of them may reach `openLink`.
     */
    @Test
    fun `every Open in Telegram control routes through openInTelegram`() {
        val controls = ArrayList<String>()
        for (file in mainSources()) {
            val lines = file.readLines()
            for ((i, line) in lines.withIndex()) {
                if (!line.contains("\"Open in Telegram\"")) continue
                val window = lines.subList(maxOf(0, i - 5), minOf(lines.size, i + 6)).joinToString("\n")
                controls += "${file.name}:${i + 1}"
                assertTrue("${file.name}:${i + 1} does not call openInTelegram", window.contains("openInTelegram("))
                assertFalse("${file.name}:${i + 1} still calls openLink", window.contains("openLink("))
            }
        }
        // §2.22.3 names six: the post sheet, the comment sheet, the blocked-node sheet, a node profile's
        // kebab, a feed channel's kebab, and the full-screen viewer. Fewer means one lost its control;
        // more means a seventh appeared and nobody checked which sentence it answers with.
        assertEquals(controls.toString(), 6, controls.size)
        // …and nothing else calls it, so the six above are the whole of its use (the declaration aside).
        val calls = mainSources().sumOf { f ->
            val text = f.readText()
            (text.split("openInTelegram(").size - 1) - (text.split("fun openInTelegram(").size - 1)
        }
        assertEquals(6, calls)
    }

    private fun mainSources(): List<File> =
        File(root(), "src/main/kotlin/ca/lucianlabs/tgsocial").walkTopDown().filter { it.extension == "kt" }.toList()

    private fun source(relative: String): String =
        File(root(), "src/main/kotlin/ca/lucianlabs/tgsocial/$relative").readText()

    private fun root(): File {
        var dir: File? = File(System.getProperty("user.dir").orEmpty())
        while (dir != null) {
            if (File(dir, "src/main/kotlin/ca/lucianlabs/tgsocial").isDirectory) return dir
            dir = dir.parentFile
        }
        fail("could not find the module root")
        error("unreachable")
    }
}
