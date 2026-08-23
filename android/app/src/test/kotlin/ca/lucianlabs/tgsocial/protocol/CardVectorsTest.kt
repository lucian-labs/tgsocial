package ca.lucianlabs.tgsocial.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.util.Locale

/** Runs every case in docs/card-vectors.json (copied into test resources by the `copyCardVectors` Gradle task). */
class CardVectorsTest {
    private val vectors: JsonObject by lazy {
        val stream = checkNotNull(javaClass.classLoader!!.getResourceAsStream("card-vectors.json")) { "card-vectors.json missing from test resources" }
        Json.parseToJsonElement(stream.reader().readText()).jsonObject
    }

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

    @Test
    fun parseVectors() {
        var count = 0
        for (case in vectors.getValue("parse").jsonArray) {
            val c = case.jsonObject
            val name = c.getValue("name").jsonPrimitive.contentOrNull
            val text = c.getValue("text").jsonPrimitive.contentOrNull.orEmpty()
            val expect = c["expect"]
            val newer = c["newerVersion"]?.jsonPrimitive?.boolean ?: false
            val result = CardFormat.parse(text)
            if (expect == null || expect is JsonNull) {
                if (newer) assertEquals("[$name] expected Newer", CardParse.Newer, result)
                else assertEquals("[$name] expected NotACard", CardParse.NotACard, result)
            } else {
                val parsed = (result as? CardParse.Parsed)?.card
                assertNotNull("[$name] expected a card, got $result", parsed)
                val e = expect.jsonObject
                assertEquals("[$name] name", e.str("name"), parsed!!.name)
                assertEquals("[$name] bio", e.str("bio"), parsed.bio)
                assertEquals("[$name] link", e.str("link"), parsed.link)
                assertEquals("[$name] public", e.getValue("public").jsonPrimitive.boolean, parsed.public)
                assertEquals("[$name] feeds", e.list("feeds"), parsed.feeds)
                assertEquals("[$name] follows", e.list("follows"), parsed.follows)
                assertEquals("[$name] replies", e.str("replies"), parsed.replies)
            }
            count++
        }
        assertTrue(count >= 12)
    }

    /** PROTOCOL §6.2 — the shared `comment` vectors: parseComment / serialiseComment. */
    @Test
    fun commentVectors() {
        val block = vectors.getValue("comment").jsonObject
        for (case in block.getValue("parse").jsonArray) {
            val c = case.jsonObject
            val input = c.getValue("in").jsonPrimitive.contentOrNull.orEmpty()
            val out = c["out"]
            val parsed = CommentFormat.parse(input)
            if (out == null || out is JsonNull) {
                assertNull("[$input] expected null", parsed)
            } else {
                assertNotNull("[$input] expected a comment", parsed)
                val e = out.jsonObject
                assertEquals("[$input] target", e.getValue("target").jsonPrimitive.contentOrNull, parsed!!.target)
                assertEquals("[$input] body", e.getValue("body").jsonPrimitive.contentOrNull, parsed.body)
            }
        }
        for (case in block.getValue("serialise").jsonArray) {
            val c = case.jsonObject
            val target = c.getValue("target").jsonPrimitive.contentOrNull.orEmpty()
            val body = c.getValue("body").jsonPrimitive.contentOrNull.orEmpty()
            assertEquals(c.getValue("out").jsonPrimitive.contentOrNull, CommentFormat.serialise(target, body))
            // Round trip: a serialised comment parses back to the same pointer.
            val reparsed = CommentFormat.parse(CommentFormat.serialise(target, body))
            assertEquals(target, reparsed?.target)
            assertEquals(body, reparsed?.body)
        }
    }

    @Test
    fun serialiseVectors() {
        for (case in vectors.getValue("serialise").jsonArray) {
            val c = case.jsonObject
            val name = c.getValue("name").jsonPrimitive.contentOrNull
            val card = c.getValue("card").jsonObject.toCard()
            assertEquals("[$name]", c.getValue("expect").jsonPrimitive.contentOrNull, CardFormat.serialise(card))
            // round trip: parse(serialise(card)) serialises back to the same text
            val reparsed = (CardFormat.parse(CardFormat.serialise(card)) as CardParse.Parsed).card
            assertEquals("[$name] round trip", c.getValue("expect").jsonPrimitive.contentOrNull, CardFormat.serialise(reparsed))
        }
    }

    @Test
    fun usernameVectors() {
        for (case in vectors.getValue("username").jsonObject.getValue("cases").jsonArray) {
            val c = case.jsonObject
            val input = c.getValue("in").jsonPrimitive.contentOrNull.orEmpty()
            val out = c.str("out")
            assertEquals("[$input]", out, Username.normalise(input))
        }
    }

    @Test
    fun deepLinkVectors() {
        for (case in vectors.getValue("deepLink").jsonObject.getValue("cases").jsonArray) {
            val c = case.jsonObject
            val username = c.getValue("username").jsonPrimitive.contentOrNull.orEmpty()
            val id = c.getValue("messageId").jsonPrimitive.long
            assertEquals(c.getValue("out").jsonPrimitive.contentOrNull, DeepLink.post(username, id))
        }
    }

    @Test
    fun backlinkVectors() {
        for (case in vectors.getValue("backlink").jsonObject.getValue("cases").jsonArray) {
            val c = case.jsonObject
            val description = c.getValue("description").jsonPrimitive.contentOrNull.orEmpty()
            val node = c.getValue("node").jsonPrimitive.contentOrNull.orEmpty()
            assertEquals("[$description]", c.getValue("out").jsonPrimitive.boolean, Backlink.isVerified(description, node))
        }
    }

    @Test
    fun timeFormatVectors() {
        val now = LocalDateTime.parse("2026-08-23T14:30:00")
        for (case in vectors.getValue("timeFormat").jsonObject.getValue("cases").jsonArray) {
            val c = case.jsonObject
            val date = LocalDateTime.parse(c.getValue("date").jsonPrimitive.contentOrNull)
            assertEquals(c.getValue("out").jsonPrimitive.contentOrNull, Format.time(date, now, Locale.ENGLISH))
        }
    }

    @Test
    fun compactCountVectors() {
        for (case in vectors.getValue("compactCount").jsonObject.getValue("cases").jsonArray) {
            val c = case.jsonObject
            val input = c.getValue("in").jsonPrimitive.int
            assertEquals("[$input]", c.getValue("out").jsonPrimitive.contentOrNull, Format.compact(input))
        }
    }

    @Test
    fun cardFullRefusesWrite() {
        val follows = (1..900).map { "tgs_user_${it.toString().padStart(4, '0')}" }
        val card = Card(name = "x", follows = follows)
        assertTrue(CardFormat.isFull(card))
        assertNull(CardParse.NotACard.cardOrNull)
    }
}
