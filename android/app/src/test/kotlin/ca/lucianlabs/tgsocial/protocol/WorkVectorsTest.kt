package ca.lucianlabs.tgsocial.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PROTOCOL §10 — the work extension, run against the same `docs/card-vectors.json` the other two clients run
 * (copied into test resources by the `copyCardVectors` Gradle task). The `work` section is the executable
 * form of §10.2–§10.4; the three tests at the bottom are the claims that are not vectors, and each of them
 * fails if the feature is removed rather than passing over its absence.
 */
class WorkVectorsTest {
    private val vectors: JsonObject by lazy {
        val stream = checkNotNull(javaClass.classLoader!!.getResourceAsStream("card-vectors.json")) { "card-vectors.json missing from test resources" }
        Json.parseToJsonElement(stream.reader().readText()).jsonObject
    }

    private val work: JsonObject by lazy { vectors.getValue("work").jsonObject }

    private fun JsonObject.str(key: String): String? = this[key]?.let { if (it is JsonNull) null else it.jsonPrimitive.contentOrNull }
    private fun JsonObject.list(key: String): List<String> = this[key]?.jsonArray?.map { it.jsonPrimitive.contentOrNull.orEmpty() } ?: emptyList()

    private fun JsonObject.toCard(): Card = Card(
        name = str("name"),
        bio = str("bio"),
        link = str("link"),
        public = this["public"]?.jsonPrimitive?.boolean ?: true,
        feeds = list("feeds"),
        follows = list("follows"),
        replies = str("replies"),
    )

    private fun JsonObject.toWork(): WorkCard = WorkCard(
        role = str("role"),
        does = list("does"),
        open = this["open"]?.takeIf { it !is JsonNull }?.jsonObject?.let {
            WorkOpen(intent = it.getValue("intent").jsonPrimitive.content, until = it.getValue("until").jsonPrimitive.content)
        },
        feeds = list("feeds"),
    )

    @Test
    fun workParseVectors() {
        var count = 0
        for (case in work.getValue("parse").jsonArray) {
            val c = case.jsonObject
            val name = c.getValue("name").jsonPrimitive.contentOrNull
            val text = c.getValue("text").jsonPrimitive.contentOrNull.orEmpty()
            val expect = c["expect"]
            val parsed = WorkFormat.parse(text)
            if (expect == null || expect is JsonNull) {
                assertNull("[$name] expected no work card, got $parsed", parsed)
            } else {
                assertNotNull("[$name] expected a work card", parsed)
                assertEquals("[$name]", expect.jsonObject.toWork(), parsed)
            }
            count++
        }
        assertEquals(10, count)
    }

    @Test
    fun workSerialiseVectors() {
        for (case in work.getValue("serialise").jsonArray) {
            val c = case.jsonObject
            val name = c.getValue("name").jsonPrimitive.contentOrNull
            val card = c.getValue("card").jsonObject.toCard()
                .copy(work = c["work"]?.takeIf { it !is JsonNull }?.jsonObject?.toWork())
            assertEquals("[$name]", c.getValue("expect").jsonPrimitive.contentOrNull, CardFormat.serialise(card))
        }
    }

    @Test
    fun workTagVectors() {
        for (case in work.getValue("tag").jsonObject.getValue("cases").jsonArray) {
            val c = case.jsonObject
            val input = c.getValue("in").jsonPrimitive.contentOrNull.orEmpty()
            assertEquals("[$input]", c.str("out"), WorkFormat.tag(input))
        }
    }

    @Test
    fun workOpenVectors() {
        for (case in work.getValue("open").jsonObject.getValue("cases").jsonArray) {
            val c = case.jsonObject
            val open = c["open"]?.takeIf { it !is JsonNull }?.jsonObject?.let {
                WorkOpen(intent = it.getValue("intent").jsonPrimitive.content, until = it.getValue("until").jsonPrimitive.content)
            }
            val today = c.getValue("today").jsonPrimitive.content
            assertEquals("[$open on $today]", c.getValue("out").jsonPrimitive.boolean, WorkFormat.openIsCurrent(open, today))
        }
    }

    @Test
    fun vouchParseVectors() {
        for (case in work.getValue("vouch").jsonObject.getValue("parse").jsonArray) {
            val c = case.jsonObject
            val input = c.getValue("in").jsonPrimitive.contentOrNull.orEmpty()
            val out = c["out"]
            val parsed = VouchFormat.parse(input)
            if (out == null || out is JsonNull) {
                assertNull("[$input] expected null, got $parsed", parsed)
            } else {
                val e = out.jsonObject
                assertNotNull("[$input] expected a vouch", parsed)
                assertEquals("[$input] node", e.getValue("node").jsonPrimitive.content, parsed!!.node)
                assertEquals("[$input] does", e.getValue("does").jsonPrimitive.content, parsed.does)
                assertEquals("[$input] body", e.getValue("body").jsonPrimitive.content, parsed.body)
            }
        }
    }

    @Test
    fun vouchSerialiseVectors() {
        for (case in work.getValue("vouch").jsonObject.getValue("serialise").jsonArray) {
            val c = case.jsonObject
            val node = c.getValue("node").jsonPrimitive.content
            val does = c.getValue("does").jsonPrimitive.content
            val body = c.getValue("body").jsonPrimitive.content
            val out = VouchFormat.serialise(node, does, body)
            assertEquals(c.getValue("out").jsonPrimitive.content, out)
            // Round trip: what the writer emits is what every reader reads back.
            val reparsed = VouchFormat.parse(out)
            assertEquals(node.removePrefix("@"), reparsed?.node)
            assertEquals(does.trim().lowercase(), reparsed?.does)
            assertEquals(body, reparsed?.body)
        }
    }

    @Test
    fun vouchSelfVectors() {
        for (case in work.getValue("vouch").jsonObject.getValue("self").jsonObject.getValue("cases").jsonArray) {
            val c = case.jsonObject
            val input = c.getValue("in").jsonPrimitive.contentOrNull.orEmpty()
            val voucher = c.getValue("voucherNode").jsonPrimitive.content
            assertEquals("[$input in $voucher]", c.getValue("out").jsonPrimitive.boolean, VouchFormat.keeps(VouchFormat.parse(input), voucher))
        }
    }

    /**
     * PROTOCOL §10's whole claim: the extension is additive, and a client that does not implement it renders
     * the card it renders today. The vector loop in `CardVectorsTest` asserts the read half through §2's own
     * parser; this asserts the **write** half, which is the one that can destroy data.
     *
     * A non-implementing client that follows somebody rewrites the card from the seven keys it knows, and the
     * work lines are gone — §10.6 is that hazard stated, not a bug, and the second half here is the round
     * trip that answers it.
     */
    @Test
    fun `§10_6 a follow keeps the work lines only when the client round-trips them`() {
        val text = work.getValue("parse").jsonArray[0].jsonObject.getValue("text").jsonPrimitive.content
        val card = (CardFormat.parse(text) as CardParse.Parsed).card
        val parsedWork = WorkFormat.parse(text)
        assertNotNull("the fixture has a work card", parsedWork)

        // §2's own parser never sets `work`: §10 is a second pass over the same bytes, not a change to §2.
        assertNull("CardFormat.parse must know nothing about §10", card.work)

        val unaware = CardFormat.serialise(card.withFollow("tgs_new"))
        assertNull("a §2-only rewrite drops §10 — this is the hazard, not a bug", WorkFormat.parse(unaware))
        assertEquals(listOf("tgs_ana", "tgs_new"), (CardFormat.parse(unaware) as CardParse.Parsed).card.follows)

        val aware = CardFormat.serialise(WorkFormat.attach(card, text)!!.withFollow("tgs_new"))
        assertEquals("an implementing client writes back what it read", parsedWork, WorkFormat.parse(aware))
        assertEquals(
            "and changes nothing a §2 client can see",
            (CardFormat.parse(unaware) as CardParse.Parsed).card,
            (CardFormat.parse(aware) as CardParse.Parsed).card.copy(work = null),
        )
    }

    /**
     * PROTOCOL §10.4 puts vouches in the comments channel §6.1 already made, so one pass over one channel
     * builds both indexes. That only holds if neither parser ever claims the other's message: a `vouch:`
     * counted as a comment would inflate a post's count, and a `re:` counted as a vouch would put a
     * stranger's reply on somebody's work card.
     */
    @Test
    fun `§10_4 one comments channel, two formats, no overlap`() {
        val channel = listOf(
            "re: https://t.me/waveloop_devlog/144\nNice one.",
            "vouch: https://t.me/tgs_elijah\ndoes: live sound\nNever missed a cue.",
            "A plain post the owner made.",
            "vouch: https://t.me/tgs_elijah\nno does line, so not a vouch",
        )
        val comments = channel.mapNotNull { CommentFormat.parse(it) }
        val vouches = channel.mapNotNull { VouchFormat.parse(it) }
        assertEquals(1, comments.size)
        assertEquals(1, vouches.size)
        assertEquals("https://t.me/waveloop_devlog/144", comments[0].target)
        assertEquals("tgs_elijah", vouches[0].node)
        for (m in channel) {
            assertFalse("$m claimed by both", CommentFormat.parse(m) != null && VouchFormat.parse(m) != null)
        }
    }

    /**
     * PROTOCOL §10.2's caps exist because the card is one 4096-character message (§2) and `follows:` has to
     * keep growing inside it. Held as numbers because three platforms have to agree on where the writer
     * refuses, and as a length because "a work card costs about what a bio costs" is a claim §10.2 makes.
     */
    @Test
    fun `§10_2 twelve tags, and a work card costs about a bio`() {
        assertEquals(12, WorkFormat.DOES_MAX)
        assertEquals(180L, WorkFormat.OPEN_HORIZON_DAYS)
        assertEquals(80, WorkFormat.ROLE_MAX)
        val text = work.getValue("parse").jsonArray[0].jsonObject.getValue("text").jsonPrimitive.content
        val bare = CardFormat.serialise((CardFormat.parse(text) as CardParse.Parsed).card)
        assertTrue("§10 added ${text.length - bare.length} characters to the card", text.length - bare.length < 200)
        assertTrue(text.length < Card.MAX_LENGTH)
    }
}
