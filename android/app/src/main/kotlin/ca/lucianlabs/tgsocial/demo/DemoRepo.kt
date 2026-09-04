package ca.lucianlabs.tgsocial.demo

import ca.lucianlabs.tgsocial.model.Comment
import ca.lucianlabs.tgsocial.model.FeedSource
import ca.lucianlabs.tgsocial.model.MyNode
import ca.lucianlabs.tgsocial.model.NodeEntry
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.protocol.SafetyLists
import ca.lucianlabs.tgsocial.protocol.Username

/**
 * PRODUCT §2.22 — one demo session: the whole invented world, in memory, with no Telegram behind it.
 *
 * §2.22.4 — **the demo is a different object, not a mode.** This class holds no reference to the TDLib client
 * and the `demo` package imports no symbol from `ca.lucianlabs.tgsocial.td` (asserted by `DemoImportsTest`),
 * so there is no code path to Telegram here to forget to guard. Media cannot reach the network either: fixture
 * refs carry no TDLib file id, and [DemoFiles] generates their bytes locally.
 *
 * §2.22.5 — **leaving persists nothing.** Everything below is a field of this object: no card cache, no feed
 * cache, no cursors, no comment index, no preference. `Leave Demo` drops the object, which is also why
 * relaunching the app leaves the demo.
 */
class DemoRepo(
    /** The demo's own epoch second. Every age in §2.22.1 is an offset from it, never a date. */
    val startedAt: Long = System.currentTimeMillis() / 1000,
) {

    /** The reader's node pointer, as a real session would hold one — synthetic ids, and never written to disk. */
    val myNode: MyNode = MyNode(
        chatId = DemoWorld.chatId(DemoWorld.READER),
        supergroupId = -DemoWorld.chatId(DemoWorld.READER),
        username = DemoWorld.READER,
        pinnedMessageId = 1L shl 20,
    )

    val me: NodeSnapshot = requireNotNull(DemoWorld.snapshot(DemoWorld.READER))

    private val allPosts: List<Post> = DemoWorld.posts(startedAt)

    /** Username key → the snapshot every surface reads, so Settings rows and the graph radial resolve names. */
    val cards: Map<String, NodeSnapshot> =
        DemoWorld.nodes.mapNotNull { DemoWorld.snapshot(it.username) }.associateBy { Username.key(it.username) }

    val feedSources: Map<String, FeedSource> =
        DemoWorld.channels.mapNotNull { DemoWorld.feedSource(it.username) }.associateBy { Username.key(it.username) }

    val comments: Map<String, List<Comment>> = DemoWorld.commentIndex(startedAt)

    /**
     * PROTOCOL §7.1 — the demo's block, mute and report state: a record **of the same shape**, in memory, with
     * no account behind it (`userId: null`, which in this `Long` field is [NO_ACCOUNT]). It lives here and
     * nowhere else — the view model's one write path sees the demo and updates this instead of calling
     * `LocalStore.saveModeration`, and a demo session never loads the stored record either. Both directions
     * matter: a demo block of `@tgs_demo_crate` must not turn up in a real account's list, and a real
     * account's blocks are not someone's demo to browse.
     */
    var safety: SafetyLists = SafetyLists(userId = NO_ACCOUNT)
        private set

    fun updateSafety(transform: (SafetyLists) -> SafetyLists): SafetyLists {
        safety = transform(safety).copy(userId = NO_ACCOUNT)
        return safety
    }

    /** §2.22.2 — the demo's `Delete My Node` really ends it; nothing survives to render afterwards. */
    var nodeDeleted: Boolean = false
        private set

    fun deleteNode() {
        nodeDeleted = true
    }

    // ------------------------------------------------------------------ feed (PRODUCT §2.3)

    private var cursor = 0

    /** The six sources the main feed merges (§2.22.1); `+1` nodes' feeds are deliberately not among them. */
    val sourceCount: Int = DemoWorld.mainFeedSources().size

    val postCount: Int = allPosts.size

    fun resetFeed() {
        cursor = 0
    }

    /**
     * One page. §2.22.1 pages **eight at a time**, so Feed loads a second page and then says
     * `That's everything.` — pagination runs, and so does §2.18's rule that a fully-filtered page fetches
     * the next one.
     */
    fun feedPage(): List<Post> {
        if (cursor >= allPosts.size) return emptyList()
        val end = (cursor + DemoWorld.PAGE).coerceAtMost(allPosts.size)
        val page = allPosts.subList(cursor, end).toList()
        cursor = end
        return page
    }

    val feedExhausted: Boolean get() = cursor >= allPosts.size

    // ------------------------------------------------------------------ profiles and channels

    fun snapshot(username: String): NodeSnapshot? = cards[Username.key(username)]

    fun feedSource(username: String): FeedSource? = feedSources[Username.key(username)]

    fun feedsOf(username: String): List<FeedSource> =
        DemoWorld.node(username)?.feeds.orEmpty().mapNotNull { feedSource(it) }

    fun followsOf(username: String): List<NodeEntry> =
        DemoWorld.node(username)?.follows.orEmpty().mapNotNull { DemoWorld.entry(it) }

    /**
     * A feed channel's own screen: every post in that channel, newest first. `+1` nodes have feeds but no
     * posts in the fixture — a reviewer who opens `arto`'s profile finds a feed with nothing in it, which is
     * a real state of the app rather than an error.
     */
    fun channelPosts(username: String): List<Post> =
        allPosts.filter { Username.same(it.sourceUsername, username) }

    // ------------------------------------------------------------------ explore and graph

    fun nearby(): List<NodeEntry> = DemoWorld.nearby()

    fun directory(): List<NodeEntry> = DemoWorld.directory()

    fun direct(): List<NodeEntry> = DemoWorld.direct()

    /** §2.4 — an exact `tgs_demo_*` username opens that profile; anything else is `Not a tgsocial node.` */
    fun find(query: String): String? = Username.normalise(query)?.let { u -> DemoWorld.node(u)?.username }

    companion object {
        /** PROTOCOL §7.1's `userId: null`, in a field typed `Long`: the value `SafetyLists()` already uses for "no account". */
        const val NO_ACCOUNT = 0L
    }
}
