package ca.lucianlabs.tgsocial.demo

import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * PRODUCT §2.22.4 — "`DemoRepo` imports nothing from the TDLib layer, and that is the build-time check: each
 * platform's test asserts that the demo sources import no symbol from the Android `td` package. It is a grep,
 * it runs in the build, and it fails the build."
 *
 * This is the whole of what makes "the demo makes no request, of any kind, to anything" a property of the
 * build rather than a discipline at each call site. A boolean can be forgotten at one branch; a package that
 * cannot name `TelegramClient` has nothing to forget.
 */
class DemoImportsTest {

    private val banned = listOf(
        "ca.lucianlabs.tgsocial.td",
        "dev.g000sha256.tdl",
        "TelegramClient",
        // The repositories are the TDLib layer's own callers; the demo must not reach Telegram through them.
        "ca.lucianlabs.tgsocial.repo",
    )

    @Test
    fun `the demo package names nothing from the TDLib layer`() {
        val sources = demoSources()
        assertTrue("no demo sources found — the check would pass vacuously", sources.size >= 5)
        val offences = ArrayList<String>()
        for (file in sources) {
            file.readLines().forEachIndexed { i, line ->
                // Doc comments may *discuss* the boundary; code may not cross it.
                val code = line.substringBefore("//").trim()
                if (code.startsWith("*") || code.startsWith("/*")) return@forEachIndexed
                for (symbol in banned) {
                    if (code.contains(symbol)) offences += "${file.name}:${i + 1}: $symbol — $code"
                }
            }
        }
        if (offences.isNotEmpty()) fail("the demo reached the TDLib layer:\n" + offences.joinToString("\n"))
    }

    private fun demoSources(): List<File> {
        var dir: File? = File(System.getProperty("user.dir").orEmpty())
        while (dir != null) {
            val candidate = File(dir, "src/main/kotlin/ca/lucianlabs/tgsocial/demo")
            if (candidate.isDirectory) return candidate.listFiles { f -> f.extension == "kt" }.orEmpty().toList()
            dir = dir.parentFile
        }
        return emptyList()
    }
}
