package ca.lucianlabs.tgsocial.demo

import ca.lucianlabs.tgsocial.model.Comment
import ca.lucianlabs.tgsocial.model.FeedSource
import ca.lucianlabs.tgsocial.model.FileRef
import ca.lucianlabs.tgsocial.model.LinkPreviewInfo
import ca.lucianlabs.tgsocial.model.NodeEntry
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.model.PostMedia
import ca.lucianlabs.tgsocial.model.PostText
import ca.lucianlabs.tgsocial.model.Reaction
import ca.lucianlabs.tgsocial.protocol.Card
import ca.lucianlabs.tgsocial.protocol.CommentFormat
import ca.lucianlabs.tgsocial.protocol.DeepLink
import ca.lucianlabs.tgsocial.protocol.Username

/**
 * PRODUCT §2.22.1 — the fixture world: fifteen invented nodes, a follow graph, fifteen posts across six
 * sources, and eleven comments in two threads. Identical on iOS, Android and web.
 *
 * Wholly invented. Nothing here is captured from a real channel, and `web/test/fixtures/` is deliberately not
 * reused — those are real people's posts. Every node username begins `tgs_demo_` and every channel `demo_`, so
 * a single card cropped out of context still says what it is (§2.22 item 3).
 *
 * This file imports nothing from `ca.lucianlabs.tgsocial.td` and nothing from `repo`, and `DemoImportsTest`
 * asserts that over the whole `demo` package: §2.22.4's guarantee is that the demo has no code path to
 * Telegram to miss, not that each call site remembered to check a flag.
 */
object DemoWorld {

    /** PRODUCT §2.22.1 — "the demo pages eight posts at a time", so pagination and `That's everything.` both run. */
    const val PAGE = 8

    const val READER = "tgs_demo_you"
    const val READER_REPLIES = "tgs_demo_you_r"

    // ------------------------------------------------------------------ nodes

    /**
     * One fixture node. [replies] is its comments channel (`PROTOCOL §6.1`); [public] is the card's
     * `public:` line, and the reader's `no` is what keeps them out of the Directory (§2.4).
     */
    data class Node(
        val username: String,
        val name: String,
        val bio: String,
        val feeds: List<String>,
        val follows: List<String> = emptyList(),
        val replies: String,
        val public: Boolean = true,
    ) {
        val card: Card get() = Card(name = name, bio = bio, public = public, feeds = feeds, follows = follows, replies = replies)
    }

    /** A fixture feed channel. [plate] is the two channels that carry a generated photo (§2.22 avatar rule). */
    data class Channel(val username: String, val title: String, val owner: String, val plate: Boolean = false, val backlink: Boolean = false)

    val nodes: List<Node> = listOf(
        Node(READER, "Demo Reader", "Looking around.", listOf("demo_you_notes"), listOf("tgs_demo_wren", "tgs_demo_mox", "tgs_demo_juno", "tgs_demo_pell"), READER_REPLIES, public = false),
        Node("tgs_demo_wren", "Wren Alderiss", "Tide clocks and bad solder.", listOf("demo_tidewright", "demo_wren_bench"), listOf("tgs_demo_mox", "tgs_demo_arto", "tgs_demo_sable", "tgs_demo_ilka"), "demo_wren_r"),
        Node("tgs_demo_mox", "Mox Petrakis", "Field recordings. Mostly rain.", listOf("demo_slow_radio"), listOf("tgs_demo_juno", "tgs_demo_arto", "tgs_demo_bly"), "demo_mox_r"),
        Node("tgs_demo_juno", "Juno Bell-Okafor", "Ceramics, mostly failures.", listOf("demo_kiln_log"), listOf("tgs_demo_pell", "tgs_demo_wren", "tgs_demo_orrin"), "demo_juno_r"),
        Node("tgs_demo_pell", "Pell Nakagawa", "Letterpress, one press.", listOf("demo_press_run"), listOf("tgs_demo_sable", "tgs_demo_hask", "tgs_demo_orrin", "tgs_demo_crate"), "demo_pell_r"),
        Node("tgs_demo_arto", "Arto Vansi", "Trail cameras on the creek.", listOf("demo_creek_cam"), replies = "demo_arto_r"),
        Node("tgs_demo_orrin", "Orrin Baptiste", "Bread, weather, complaints.", listOf("demo_proof_box"), replies = "demo_orrin_r"),
        Node("tgs_demo_sable", "Sable Quiring", "Maps nobody asked for.", listOf("demo_paper_maps"), replies = "demo_sable_r"),
        Node("tgs_demo_bly", "Bly Toussaint", "Night sky, cheap lens.", listOf("demo_dark_sky"), replies = "demo_bly_r"),
        Node("tgs_demo_hask", "Hask Oyelaran", "Fixes the ferry radio.", listOf("demo_ferry_net"), replies = "demo_hask_r"),
        Node("tgs_demo_ilka", "Ilka Ferreira", "Bike frames.", listOf("demo_frame_jig"), replies = "demo_ilka_r"),
        Node("tgs_demo_crate", "Crate Mailer", "Free crates. Ask me.", listOf("demo_free_crates"), replies = "demo_crate_r"),
        Node("tgs_demo_lume", "Lume Adeyemi", "Neon repair.", listOf("demo_neon_bench"), replies = "demo_lume_r"),
        Node("tgs_demo_noor", "Noor Salk", "Weather balloons.", listOf("demo_balloon_log"), replies = "demo_noor_r"),
        Node("tgs_demo_veda", "Veda Marchetti", "Sails.", listOf("demo_sail_loft"), replies = "demo_veda_r"),
    )

    val channels: List<Channel> = listOf(
        Channel("demo_you_notes", "My Notes", READER),
        Channel("demo_tidewright", "Tidewright", "tgs_demo_wren", plate = true, backlink = true),
        Channel("demo_wren_bench", "Wren's Bench", "tgs_demo_wren"),
        Channel("demo_slow_radio", "Slow Radio", "tgs_demo_mox", plate = true),
        Channel("demo_kiln_log", "Kiln Log", "tgs_demo_juno", backlink = true),
        Channel("demo_press_run", "Press Run", "tgs_demo_pell"),
        Channel("demo_creek_cam", "Creek Cam", "tgs_demo_arto"),
        Channel("demo_proof_box", "Proof Box", "tgs_demo_orrin"),
        Channel("demo_paper_maps", "Paper Maps", "tgs_demo_sable"),
        Channel("demo_dark_sky", "Dark Sky", "tgs_demo_bly"),
        Channel("demo_ferry_net", "Ferry Net", "tgs_demo_hask"),
        Channel("demo_frame_jig", "Frame Jig", "tgs_demo_ilka"),
        Channel("demo_free_crates", "Free Crates", "tgs_demo_crate"),
        Channel("demo_neon_bench", "Neon Bench", "tgs_demo_lume"),
        Channel("demo_balloon_log", "Balloon Log", "tgs_demo_noor"),
        Channel("demo_sail_loft", "Sail Loft", "tgs_demo_veda"),
    )

    private val nodesByKey: Map<String, Node> = nodes.associateBy { Username.key(it.username) }
    private val channelsByKey: Map<String, Channel> = channels.associateBy { Username.key(it.username) }

    fun node(username: String?): Node? = username?.let { nodesByKey[Username.key(it)] }
    fun channel(username: String?): Channel? = username?.let { channelsByKey[Username.key(it)] }

    val reader: Node get() = nodesByKey.getValue(Username.key(READER))

    /** PROTOCOL §2 — the reader's card, serialised. The literal vector the three parsers agree on (§2.22.1). */
    fun readerCardText(): String = reader.card.serialise()

    /**
     * Chat ids are synthetic and negative — a real Telegram supergroup chat id is negative too, and nothing in
     * the demo ever hands one to anything that could resolve it. Derived from the username so a post, its
     * channel and its viewer all agree without a registry to keep in step.
     */
    fun chatId(username: String): Long = -1_000_000_000_000L - (Username.key(username).hashCode().toLong() and 0xFFFFFF)

    /** Channel photos: two of them, so §2.3's first avatar fallback branch paints and the rest fall to initials. */
    private fun channelPhoto(c: Channel): FileRef? =
        if (c.plate) DemoMedia.ref("${c.username}/avatar", 320, 320) else null

    fun snapshot(username: String): NodeSnapshot? {
        val n = node(username) ?: return null
        return NodeSnapshot(
            username = n.username,
            chatId = chatId(n.username),
            supergroupId = -chatId(n.username),
            title = n.name,
            description = "tgsocial v1 · ${n.bio}",
            photo = null,
            card = n.card,
            fetchedAt = 0L,
        )
    }

    fun feedSource(username: String): FeedSource? {
        val c = channel(username) ?: return null
        return FeedSource(
            username = c.username,
            chatId = chatId(c.username),
            supergroupId = -chatId(c.username),
            title = c.title,
            description = if (c.backlink) "tgsocial: @${c.owner}" else "",
            photo = channelPhoto(c),
            listedBy = listOf(c.owner),
            // PROTOCOL §3 — the backlink is what earns the `Verified` pill, and two feeds carry one so both
            // states are on screen (§2.22.1).
            verifiedFor = if (c.backlink) listOf(c.owner) else emptyList(),
        )
    }

    fun entry(username: String, mutual: Int = 0): NodeEntry? {
        val n = node(username) ?: return null
        return NodeEntry(username = n.username, name = n.name, feedCount = n.feeds.size, mutualCount = mutual)
    }

    // ------------------------------------------------------------------ the graph (PRODUCT §2.4 / §2.7)

    /** The reader's direct follows, in card order — `DIRECT · 4`. */
    fun direct(): List<NodeEntry> = reader.follows.mapNotNull { entry(it) }

    /**
     * PROTOCOL §5.1 — the nodes my follows follow, ranked by how many of mine list them, ties broken by
     * username ascending. Spelled out in §2.22.1 because otherwise three platforms produce three orders:
     * `arto` (2), `orrin` (2), `sable` (2), `bly` (1), `crate` (1), `hask` (1), `ilka` (1).
     */
    fun nearby(): List<NodeEntry> {
        val skip = HashSet<String>()
        skip += Username.key(READER)
        reader.follows.forEach { skip += Username.key(it) }
        val counts = LinkedHashMap<String, Int>()
        for (f in reader.follows) {
            val snap = node(f) ?: continue
            for (second in snap.follows) {
                val k = Username.key(second)
                if (k in skip) continue
                counts[k] = (counts[k] ?: 0) + 1
            }
        }
        return counts.entries
            .sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
            .mapNotNull { (k, n) -> node(k)?.takeIf { it.public }?.let { entry(it.username, n) } }
    }

    /** §2.4 DIRECTORY — the nodes in no walk at all: `lume`, `noor`, `veda`. */
    fun directory(): List<NodeEntry> {
        val seen = HashSet<String>()
        seen += Username.key(READER)
        reader.follows.forEach { seen += Username.key(it) }
        nearby().forEach { seen += Username.key(it.username) }
        return nodes.filter { it.public && Username.key(it.username) !in seen }.mapNotNull { entry(it.username) }
    }

    // ------------------------------------------------------------------ posts (PRODUCT §2.22.1)

    /**
     * One row of §2.22.1's post table. [age] is an offset from the moment the demo started, never a date, so
     * §2.3's relative ladder reads correctly in a review a year from now.
     */
    private data class Row(
        val channel: String,
        val id: Long,
        val age: Long,
        val text: String? = null,
        val media: (Row.() -> List<PostMedia>)? = null,
        val preview: LinkPreviewInfo? = null,
        val album: Boolean = false,
    ) {
        val key: String get() = "$channel/$id"
    }

    private const val MIN = 60L
    private const val HOUR = 3_600L
    private const val DAY = 86_400L

    /**
     * Every rung of §2.3's ladder is on this list — `now`, `6m`, `22m`, `2h`, `1d`, `2w`, `4mo`, `2y` — so a
     * wrong rounding is visible without arithmetic. The day-scale offsets carry an extra hour so a floor
     * division lands on the rung the table names rather than on its boundary.
     */
    private val rows: List<Row> = listOf(
        Row("demo_tidewright", 147, 40, "Tide clock is off by nine minutes and I know exactly why."),
        Row(
            "demo_slow_radio", 101, 6 * MIN, "Three in the morning, and it did not let up.",
            media = { listOf(PostMedia.Audio(DemoMedia.ref("$key·1", 0, 0), "Rain on the shed roof", "Slow Radio", "rain-on-the-shed-roof.wav", 222, "audio/wav")) },
        ),
        Row(
            "demo_kiln_log", 224, 22 * MIN, "Glaze tests. Two of these are the same glaze.", album = true,
            media = {
                listOf(4 to 3, 3 to 4, 1 to 1, 16 to 9).mapIndexed { i, (w, h) ->
                    val width = 1280
                    PostMedia.Photo(DemoMedia.ref("$key·${i + 1}", width, width * h / w), width, width * h / w)
                }
            },
        ),
        Row(
            "demo_press_run", 72, 2 * HOUR, "Found this while cleaning out a drawer.",
            preview = LinkPreviewInfo(
                url = "https://example.com/em-dash",
                siteName = "example.com",
                title = "A Short History of the Em Dash",
                description = "Why the long dash outlived the metal it was cast in.",
                thumb = DemoMedia.ref("demo_press_run/72·link", 640, 360),
            ),
        ),
        Row(
            "demo_wren_bench", 17, 5 * HOUR, "Someone scanned the 1971 tables. All of them.",
            media = { listOf(PostMedia.Document(DemoMedia.ref("$key·1", 0, 0), "tide-table-1971.pdf", "application/pdf", 2_516_582L)) },
        ),
        Row("demo_you_notes", 2, 9 * HOUR, "Testing the demo. This one is mine."),
        Row(
            "demo_slow_radio", 95, 14 * HOUR, "The ferry leaving in fog.",
            media = {
                listOf(
                    PostMedia.Video(
                        file = DemoMedia.ref("$key·1", 720, 405),
                        thumb = DemoMedia.ref("$key·poster", 720, 405),
                        width = 720, height = 405, durationSeconds = 18, mimeType = "video/mp4",
                    ),
                )
            },
        ),
        Row("demo_tidewright", 144, DAY + HOUR, "New moon. Everything in the harbour is six inches lower than it should be."),
        Row(
            "demo_kiln_log", 219, 2 * DAY + HOUR, "Failure on the left.",
            media = { listOf(PostMedia.Photo(DemoMedia.ref("$key·1", 1080, 1080), 1080, 1080)) },
        ),
        Row(
            "demo_press_run", 71, 3 * DAY + HOUR, null,
            media = {
                listOf(
                    PostMedia.Voice(
                        file = DemoMedia.ref("$key·1", 0, 0),
                        durationSeconds = 47,
                        // PRODUCT §2.11.2 — Telegram-shaped waveform bytes ship in the fixture, so the
                        // draw-immediately-then-analyse path is the one that runs rather than the cold one.
                        waveform = DemoMedia.voiceWaveform("$key·1"),
                        mimeType = "audio/wav",
                    ),
                )
            },
        ),
        Row("demo_wren_bench", 12, 6 * DAY + HOUR, "Ordered the wrong solder again."),
        Row(
            "demo_slow_radio", 88, 14 * DAY + HOUR, null,
            media = {
                listOf(
                    PostMedia.Animation(
                        file = DemoMedia.ref("$key·1", 480, 480),
                        thumb = DemoMedia.ref("$key·poster", 480, 480),
                        width = 480, height = 480, mimeType = "video/mp4",
                    ),
                )
            },
        ),
        Row("demo_kiln_log", 203, 35 * DAY + HOUR, "Kiln is at cone six and holding."),
        Row("demo_press_run", 58, 122 * DAY + HOUR, "The press is level. It only took a year."),
        Row("demo_you_notes", 1, 740 * DAY + HOUR, "First post."),
    )

    /** The six sources the main feed merges: the reader's own feed plus the five feeds of the four they follow. */
    fun mainFeedSources(): List<String> =
        (reader.feeds + reader.follows.flatMap { node(it)?.feeds.orEmpty() }).distinct()

    /**
     * PRODUCT §2.3 — reactions and views **derive from the message id** rather than being invented per row, so
     * all three builds print the same figures without a fourth table to keep in step.
     */
    fun reactionCount(id: Long): Int = ((id * 7) % 23).toInt()
    fun viewCount(id: Long): Int = (60 + (id * 37) % 900).toInt()

    /** Every fixture post, newest first — the order Feed paints them. [start] is the demo's own epoch second. */
    fun posts(start: Long): List<Post> = rows.map { it.toPost(start) }

    private fun Row.toPost(start: Long): Post {
        val c = channels.first { Username.same(it.username, channel) }
        val owner = node(c.owner)
        val reactions = reactionCount(id).let { if (it == 0) emptyList() else listOf(Reaction("👍", it)) }
        return Post(
            chatId = chatId(channel),
            // PROTOCOL §4.8 — TDLib shifts server ids 20 bits, and `DeepLink`/`CommentFormat` shift them back.
            // The fixtures carry the shifted form so a demo post's key and t.me link are built by the same code
            // a real post's are.
            messageId = id shl 20,
            date = (start - age).toInt(),
            sourceUsername = c.username,
            sourceTitle = c.title,
            sourcePhoto = channelPhoto(c),
            nodeUsername = owner?.username,
            nodeName = owner?.name,
            nodePhoto = null,
            text = text?.let { PostText(it) },
            media = media?.invoke(this).orEmpty(),
            linkPreview = preview,
            views = viewCount(id),
            reactions = reactions,
            albumId = if (album) id else 0L,
        )
    }

    // ------------------------------------------------------------------ comments (PROTOCOL §6)

    private data class C(val channel: String, val id: Long, val age: Long, val target: String, val body: String)

    /**
     * §2.22.1 — eleven comments in two threads. The first is five on `demo_tidewright/144` including a
     * three-deep `re:` chain and the spam comment; the second is one chain six deep on `demo_kiln_log/219`, so
     * §2.12's depth-5 cap flattens its last row.
     */
    private val commentRows: List<C> = listOf(
        C("demo_mox_r", 31, 22 * HOUR, "demo_tidewright/144", "Six inches is the whole reason I stopped trusting that gauge."),
        C("demo_wren_r", 40, 21 * HOUR, "demo_mox_r/31", "The gauge is fine. The pier moved."),
        C("demo_mox_r", 32, 20 * HOUR, "demo_wren_r/40", "Then the pier moved."),
        C("demo_juno_r", 9, 19 * HOUR, "demo_tidewright/144", "Photograph the pier or it didn't happen."),
        C("demo_crate_r", 12, 18 * HOUR, "demo_tidewright/144", "FREE CRATES today only, message me for the link."),
        C("demo_wren_r", 41, 47 * HOUR, "demo_kiln_log/219", "Which one is the failure?"),
        C("demo_juno_r", 10, 46 * HOUR, "demo_wren_r/41", "Both."),
        C("demo_wren_r", 42, 45 * HOUR, "demo_juno_r/10", "Then it worked."),
        C("demo_juno_r", 11, 44 * HOUR, "demo_wren_r/42", "It cracked."),
        C("demo_mox_r", 33, 43 * HOUR, "demo_juno_r/11", "It always cracks."),
        C("demo_wren_r", 43, 42 * HOUR, "demo_mox_r/33", "Agreed."),
    )

    /** Which node owns a comments channel, and whether they are reached at +1 rather than directly (§6.3). */
    private fun commentAuthor(channel: String): Node? =
        nodes.firstOrNull { Username.same(it.replies, channel) }

    fun isPlusOne(username: String): Boolean {
        val k = Username.key(username)
        if (k == Username.key(READER)) return false
        if (reader.follows.any { Username.key(it) == k }) return false
        return nearby().any { Username.key(it.username) == k }
    }

    /**
     * The comment index, in the shape `CommentRepo` publishes: normalised target key → comments newest first.
     * `CommentThread` walks it, so the demo's threads, counts and depth cap are the real ones.
     */
    fun commentIndex(start: Long): Map<String, List<Comment>> {
        val map = LinkedHashMap<String, MutableList<Comment>>()
        for (row in commentRows) {
            val author = commentAuthor(row.channel) ?: continue
            val date = (start - row.age).toInt()
            val messageId = row.id shl 20
            val comment = Comment(
                chatId = chatId(row.channel),
                messageId = messageId,
                date = date,
                channelUsername = row.channel,
                authorUsername = author.username,
                authorName = author.name,
                authorPhoto = null,
                targetKey = row.target,
                link = DeepLink.post(row.channel, messageId),
                post = Post(
                    chatId = chatId(row.channel),
                    messageId = messageId,
                    date = date,
                    sourceUsername = row.channel,
                    sourceTitle = author.name,
                    text = PostText(row.body),
                ),
                // `crate` is reached at +1 through `pell`, so their comment is in §6.3 scope and carries the pill.
                plusOne = isPlusOne(author.username),
                own = Username.same(author.username, READER),
            )
            map.getOrPut(row.target) { mutableListOf() } += comment
        }
        for (list in map.values) list.sortWith(compareByDescending<Comment> { it.date }.thenByDescending { it.messageId })
        return map
    }

    /** The §6.2 key of a post — what its comments carry as their target. */
    fun postKey(post: Post): String = CommentFormat.postKey(post.sourceUsername, post.messageId)
}
