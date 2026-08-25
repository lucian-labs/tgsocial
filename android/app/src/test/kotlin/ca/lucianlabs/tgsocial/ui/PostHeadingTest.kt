package ca.lucianlabs.tgsocial.ui

import ca.lucianlabs.tgsocial.model.FileRef
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.ui.components.PostHeading
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * PRODUCT §2.3 — the post avatar is the SOURCE CHANNEL, and the fallback chain that backs it up:
 * source channel photo → node photo → initial.
 */
class PostHeadingTest {

    private val channelPhoto = FileRef(id = 1, uniqueId = "channel")
    private val nodePhoto = FileRef(id = 2, uniqueId = "node")

    private fun post(
        sourcePhoto: FileRef? = null,
        nodeUsername: String? = "ana",
        nodeName: String? = "Ana Iliovic",
        nodePhoto: FileRef? = null,
        sourceTitle: String = "WaveLoop devlog",
    ) = Post(
        chatId = 1L,
        messageId = 2L,
        date = 0,
        sourceUsername = "tgs_waveloop",
        sourceTitle = sourceTitle,
        sourcePhoto = sourcePhoto,
        nodeUsername = nodeUsername,
        nodeName = nodeName,
        nodePhoto = nodePhoto,
    )

    @Test
    fun `the source channel photo wins over the node's own`() {
        val h = PostHeading.of(post(sourcePhoto = channelPhoto, nodePhoto = nodePhoto))
        assertEquals(channelPhoto, h.photo)
        // The name beside it is still the person.
        assertEquals("Ana Iliovic", h.name)
        assertEquals("WaveLoop devlog", h.channelTitle)
    }

    @Test
    fun `an unphotographed channel falls through to the node's photo`() {
        // Telegram draws a generated letter avatar for a channel with no photo; TDLib reports `chat.photo ==
        // null`, so the source photo simply is not there and must not block the fallback.
        val h = PostHeading.of(post(sourcePhoto = null, nodePhoto = nodePhoto))
        assertEquals(nodePhoto, h.photo)
    }

    @Test
    fun `no photo anywhere leaves the initial`() {
        val h = PostHeading.of(post(sourcePhoto = null, nodePhoto = null))
        assertNull(h.photo)
        assertEquals("A", h.initial)
    }

    @Test
    fun `two posts by the same person from different feeds get different avatars`() {
        val devlog = FileRef(id = 3, uniqueId = "devlog")
        val studio = FileRef(id = 4, uniqueId = "studio")
        val a = PostHeading.of(post(sourcePhoto = devlog, nodePhoto = nodePhoto, sourceTitle = "WaveLoop devlog"))
        val b = PostHeading.of(post(sourcePhoto = studio, nodePhoto = nodePhoto, sourceTitle = "Studio notes"))
        assertEquals(a.name, b.name)
        assertEquals(devlog, a.photo)
        assertEquals(studio, b.photo)
    }

    @Test
    fun `an unattributed post is the channel itself, with no subheading`() {
        val h = PostHeading.of(post(sourcePhoto = channelPhoto, nodeUsername = null, nodeName = null))
        assertEquals("WaveLoop devlog", h.name)
        assertNull(h.channelTitle)
        assertNull(h.nodeUsername)
        assertEquals(channelPhoto, h.photo)
        assertEquals("W", h.initial)
    }

    @Test
    fun `a node with no card name falls back to its username`() {
        val h = PostHeading.of(post(nodeName = null))
        assertEquals("@ana", h.name)
        assertEquals("a", h.initial)
    }

    @Test
    fun `a name with no letters or digits still gets an initial`() {
        val h = PostHeading.of(post(nodeName = "★"))
        assertEquals("·", h.initial)
    }
}
