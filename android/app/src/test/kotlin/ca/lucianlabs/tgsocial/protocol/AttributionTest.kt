package ca.lucianlabs.tgsocial.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * PRODUCT §2.3 — attribution: the post header is the node the post reaches me through. My feed → me; a
 * followed node's feed → that node; several listing nodes → the earliest in my `follows:` order; none → null
 * (the card falls back to the channel).
 */
class AttributionTest {
    private val myCard = Card(
        name = "Me",
        feeds = listOf("my_feed"),
        follows = listOf("tgs_ana", "tgs_bob"),
    )
    private val cards = mapOf(
        "tgs_ana" to Card(name = "Ana Iliovic", feeds = listOf("ana_notes", "shared_feed")),
        "tgs_bob" to Card(name = "Bob", feeds = listOf("bob_feed", "shared_feed")),
    )

    private fun resolve(feed: String, myUsername: String? = "tgs_me", card: Card? = myCard): String? =
        Attribution.resolve(feed, myUsername, card) { cards[Username.key(it)] }

    @Test
    fun myFeedAttributesToMe() {
        assertEquals("tgs_me", resolve("my_feed"))
        // Card usernames are case-insensitive (PROTOCOL §2).
        assertEquals("tgs_me", resolve("MY_FEED"))
    }

    @Test
    fun followedNodesFeedAttributesToThatNode() {
        assertEquals("tgs_bob", resolve("bob_feed"))
        assertEquals("tgs_ana", resolve("ana_notes"))
    }

    @Test
    fun twoNodesListingOneFeedResolveToEarliestInFollowsOrder() {
        // Both Ana and Bob list shared_feed; Ana is earlier in my follows order.
        assertEquals("tgs_ana", resolve("shared_feed"))
    }

    @Test
    fun unattributedFeedResolvesToNull() {
        assertNull(resolve("nobody_lists_this"))
        assertNull(resolve("my_feed", card = null))
    }
}
