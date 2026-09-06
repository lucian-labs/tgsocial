package ca.lucianlabs.tgsocial.ui

import android.net.Uri
import ca.lucianlabs.tgsocial.model.Comment
import ca.lucianlabs.tgsocial.model.FeedCandidate
import ca.lucianlabs.tgsocial.model.FileRef
import ca.lucianlabs.tgsocial.model.FeedSource
import ca.lucianlabs.tgsocial.model.NodeEntry
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.model.Vouch
import ca.lucianlabs.tgsocial.protocol.CommentTarget
import ca.lucianlabs.tgsocial.protocol.ReportSubject
import ca.lucianlabs.tgsocial.protocol.SafetyFilter
import ca.lucianlabs.tgsocial.protocol.SafetyLists
import ca.lucianlabs.tgsocial.protocol.Username
import ca.lucianlabs.tgsocial.protocol.WorkCard
import ca.lucianlabs.tgsocial.protocol.WorkFormat

enum class AuthStep { LOADING, PHONE, CODE, PASSWORD, OTHER_DEVICE, REGISTRATION, READY }

data class AuthUi(
    val step: AuthStep = AuthStep.LOADING,
    val passwordHint: String = "",
    val qrLink: String? = null,
    val busy: Boolean = false,
)

enum class Tab(val label: String) { FEED("Feed"), EXPLORE("Explore"), GRAPH("Graph"), YOU("You") }

sealed class Screen {
    data object Home : Screen()
    data object Setup : Screen()
    /** Manage feeds (You → Manage): the Setup feeds card alone. */
    data object ManageFeeds : Screen()
    data class Profile(val username: String) : Screen()
    data class FeedChannel(val username: String) : Screen()
    /** PRODUCT §2.12 — the thread screen for one post. */
    data class Thread(val post: Post) : Screen()
    /** PRODUCT §2.20 — the safety lists, the contact card, and the two destructive actions. */
    data object Settings : Screen()

    /**
     * PRODUCT §2.25 — the vouches for one capability of one node. The tag is carried rather than looked up:
     * `VOUCHED, NOT CLAIMED` rows point at tags the subject's own card does not list (PROTOCOL §10.4), so
     * there is nothing on the card to resolve them from.
     */
    data class Vouches(val username: String, val tag: String) : Screen()
}

sealed class Sheet {
    data class Compose(val feedUsername: String?) : Sheet()
    data object EditCard : Sheet()
    data object SignOut : Sheet()
    /** PRODUCT §2.10 — the Status sheet, opened by tapping the status pill. */
    data object Status : Sheet()
    /** PRODUCT §2.22.5 — the demo sheet, which takes the status sheet's place for as long as the demo runs. */
    data object Demo : Sheet()
    /**
     * PRODUCT §2.12 — the comment composer. It carries the **post** as well as the target because clearing
     * the reply target (the quote's `×`) does not close the composer — it re-aims it at the post, and the
     * composer has to know which one that is.
     */
    data class CommentComposer(val post: Post, val target: CommentTarget) : Sheet()
    data class DeleteComment(val comment: Comment) : Sheet()
    /** PRODUCT §2.3 — the long-press post sheet: exact date, views, feed, and the one `Open in Telegram`. */
    data class PostSheet(val post: Post) : Sheet()
    /** PRODUCT §2.12 / §2.15 — the long-press comment sheet: the same modal with the comment's own rows. */
    data class CommentSheet(val comment: Comment) : Sheet()
    /** PRODUCT §2.15 — the report confirm; what is being reported lives in [ReportUi]. */
    data object Report : Sheet()
    /** PRODUCT §2.16 — `Block @tgs_ana?`. */
    data class Block(val username: String) : Sheet()
    /** PRODUCT §2.21 — type the username to confirm. */
    data object DeleteNode : Sheet()

    /** PRODUCT §2.25 — `( Vouch for Ana )`: one capability, one message, in my own comments channel. */
    data class Vouch(val username: String) : Sheet()

    /** PRODUCT §2.25 — the long-press vouch sheet: §2.12's comment sheet with two strings changed. */
    data class VouchSheet(val vouch: ca.lucianlabs.tgsocial.model.Vouch) : Sheet()

    data class DeleteVouch(val vouch: ca.lucianlabs.tgsocial.model.Vouch) : Sheet()
}

/**
 * PRODUCT §2.11 — the full-screen viewer over one post's media, opened at [page].
 *
 * PRODUCT §2.12 — [commentsOpen] does not leave the media: the pages shrink to the mini view and the thread
 * takes the rest of the sheet. [page] is live rather than initial, because the thread is targeted at the
 * current item's post: paging the carousel re-targets it. Every page of one viewer belongs to one post on
 * this build (a viewer is opened over a post's own album), so [current] is that post — but the thread reads
 * it through the page, which is what makes the rule true rather than incidentally true.
 */
data class ViewerUi(val post: Post, val page: Int, val commentsOpen: Boolean = false) {
    val current: Post get() = post
}

data class FeedUi(
    val posts: List<Post> = emptyList(),
    val loading: Boolean = false,
    val refreshing: Boolean = false,
    val exhausted: Boolean = false,
    val sourceCount: Int = 0,
    val ready: Boolean = false,
    /** Epoch ms of the last completed refresh — the Status sheet's `refreshed HH:mm`. */
    val refreshedAt: Long = 0,
    /**
     * A post arrived live that is newer than everything the window holds, and the window is full (see
     * `FeedOrder.window`). The feed shows a `Newer posts` jump rather than losing it silently; a refresh clears it.
     */
    val newerAvailable: Boolean = false,
    /**
     * PRODUCT §2.18 — how many of [posts] the filter took on the way to the screen. Zero on the unfiltered
     * state the view model holds; set by [filtered], which is the only thing a screen renders.
     */
    val filteredOut: Int = 0,
) {
    /**
     * PRODUCT §2.18 — "a page whose items are all filtered fetches the next one rather than rendering an
     * empty list". This is that state: pages have loaded, the filter took every one of them, and there is
     * more to fetch. It is **not** an empty feed, so the screen must not say `Nothing here yet.` — and the
     * scroll cannot ask for the next page, because nothing it can see changed when the page vanished.
     */
    val chaining: Boolean get() = ready && posts.isEmpty() && filteredOut > 0 && !exhausted

    /** The reader's view of this feed: filtered, and told how much the filter took (§2.18). */
    fun filtered(lists: SafetyLists): FeedUi {
        val visible = SafetyFilter.posts(posts, lists, mainFeed = true)
        return copy(posts = visible, filteredOut = posts.size - visible.size)
    }
}

data class ExploreUi(
    val query: String = "",
    val nearby: List<NodeEntry> = emptyList(),
    val directory: List<NodeEntry> = emptyList(),
    val loading: Boolean = false,
    val loaded: Boolean = false,
    /**
     * PRODUCT §2.24 — `WHAT THEY DO`. Derived from the cards this client has already read, never fetched:
     * PROTOCOL §10.7.2 is blunt that Telegram will not return a node because of a tag inside its pinned
     * message, so this is a local filter over the reader's own graph plus the directory, and the screen says
     * so in a permanent line rather than in a footnote.
     */
    val capability: List<CapabilityHit> = emptyList(),
)

/** One `WHAT THEY DO` hit: the node, and which of their own tags the query matched. */
data class CapabilityHit(val entry: NodeEntry, val tags: List<String>)

/**
 * PRODUCT §2.24 — the two ways Feed is read. Deliberately a mode and not a fifth tab: a tab would say there
 * are two networks and there is one — the same nodes, the same follows, the same cards, read two ways, which
 * is the whole claim PROTOCOL §10 exists to prove.
 */
enum class FeedMode(val label: String) { ALL("All"), WORK("Work") }

/**
 * PRODUCT §2.24 — one `OPEN NOW` row. [plusOne] is included here and nowhere else in the mode: intent is a
 * small structured line on a card the client already fetched for Explore and Graph, so one more hop is free,
 * while walking a +1 node's feed history would be a fetch per channel.
 */
data class OpenIntent(
    val username: String,
    val name: String,
    val photo: FileRef?,
    val initial: String,
    val intent: String,
    val until: String,
    val tags: List<String>,
    val plusOne: Boolean,
)

/**
 * PRODUCT §2.24 — Work mode's own state. [available] gates the mode control itself: a reader whose network
 * carries no `work.feeds` sees Feed exactly as it is today, because the surface is additive or it is not
 * additive.
 */
data class WorkUi(
    val available: Boolean = false,
    val openNow: List<OpenIntent> = emptyList(),
    val posts: List<Post> = emptyList(),
    /** My own follow count — under five, `OPEN NOW`'s empty state says why it is short. */
    val followCount: Int = 0,
    /**
     * The state of the feed the column is a filter over. The work column is a view of the merged window
     * (§4.8), so `That's everything.` under it is only true when the merge itself is exhausted — an unmarked
     * page still to come could carry work posts.
     */
    val loading: Boolean = false,
    val exhausted: Boolean = false,
    /**
     * How many posts of the merged window the work filter took on the way to [posts] — the only thing that
     * can tell the screen a page vanished whole. Set by [column], which is what the view model renders.
     */
    val filteredOut: Int = 0,
) {
    /**
     * PRODUCT §2.18's rule, which the work column needs for the same reason the safety filter does: "a page
     * whose items are all filtered fetches the next one rather than rendering an empty list."
     *
     * The pager fires off the LazyColumn's item count, and a page that goes entirely into the work filter
     * does not change it — so the predicate never leaves `true`, never emits again, and the mode stalls after
     * exactly one extra page. Without this the reader lands on `No work posts yet.` / `Mark one of your feeds
     * as work` — advice that is already satisfied, since the mode control is only drawn when the network
     * carries a `work.feeds` entry — with the work posts sitting unfetched below the window.
     */
    val chaining: Boolean get() = !loading && posts.isEmpty() && filteredOut > 0 && !exhausted

    /**
     * The work column: the merged window (§4.8) with every post from a feed nobody marked work suppressed.
     * That is the entire filter — no scoring, no promotion, no "relevant to you" — and [filteredOut] is what
     * it took.
     */
    fun column(feed: FeedUi, workFeeds: Set<String>): WorkUi {
        val visible = feed.posts.filter { Username.key(it.sourceUsername) in workFeeds }
        return copy(
            posts = visible,
            filteredOut = feed.posts.size - visible.size,
            loading = feed.loading || !feed.ready,
            exhausted = feed.exhausted,
        )
    }
}

data class GraphUi(
    val direct: List<NodeEntry> = emptyList(),
    val plusOne: List<NodeEntry> = emptyList(),
    val loading: Boolean = false,
    val loaded: Boolean = false,
)

data class ProfileUi(
    val username: String = "",
    val snapshot: NodeSnapshot? = null,
    val loading: Boolean = false,
    val notANode: Boolean = false,
    val newerVersion: Boolean = false,
    val feeds: List<FeedSource> = emptyList(),
    val follows: List<NodeEntry> = emptyList(),
    /**
     * PRODUCT §2.16 — the one place a blocked node is drawn at all. Everywhere else it is dropped; a profile
     * is reached deliberately (a t.me link, a public URL, an exact-username search) and an empty screen there
     * reads as a broken app, so it says so and offers `Unblock`.
     */
    val blocked: Boolean = false,
)

data class ChannelUi(
    val username: String = "",
    val source: FeedSource? = null,
    val posts: List<Post> = emptyList(),
    val loading: Boolean = false,
    val cursor: Long? = null,
    val exhausted: Boolean = false,
    val verified: Boolean = false,
    /** PRODUCT §2.17 — the kebab reads `Unmute Feed`; the channel's own screen stays complete either way. */
    val muted: Boolean = false,
)

enum class Availability { UNKNOWN, CHECKING, AVAILABLE, TAKEN }

data class SetupUi(
    val nodeName: String = "",
    val availability: Availability = Availability.UNKNOWN,
    val availabilityNote: String = "",
    val creating: Boolean = false,
    val candidates: List<FeedCandidate> = emptyList(),
    val candidatesLoading: Boolean = false,
    val selected: Set<String> = emptySet(),
    /** Feed username awaiting the Verify / Skip answer. */
    val verifyPrompt: String? = null,
    val verified: Set<String> = emptySet(),
    val saving: Boolean = false,
)

data class ComposeUi(
    val feeds: List<FeedSource> = emptyList(),
    val selected: Int = 0,
    val text: String = "",
    val photo: Uri? = null,
    val posting: Boolean = false,
)

/**
 * PRODUCT §2.8 / §2.23 — the Edit Card modal. The §2 fields are unchanged; everything below [role] is the
 * work section, and all of it is optional. [openIntent] null is the `Nothing` tab, which is the state of
 * every card written before PROTOCOL §10 existed.
 */
data class EditCardUi(
    val name: String = "",
    val bio: String = "",
    val link: String = "",
    val saving: Boolean = false,
    val role: String = "",
    /** True once a paste was cut at 80 — the field's faint `Trimmed to 80.` (§2.23). */
    val roleTrimmed: Boolean = false,
    val does: String = "",
    val openIntent: String? = null,
    val openDays: Int = 30,
    /** Feed usernames (key form) toggled as work. Intersected with my `feeds:` on save (PROTOCOL §10.2). */
    val workFeeds: Set<String> = emptySet(),
) {
    /** The end date the FOR tabs write, derived at save time and shown under them — never typed (§2.23). */
    val endsOn: String get() = WorkFormat.horizonDate(openDays)
}

/**
 * PRODUCT §2.23 — what the `WORK` section of a profile is made of, decided in one pure place.
 *
 * Both of these read a node's own card **and** the vouches about it, because those are two different
 * people's writing: a vouch lives in the voucher's channel and names its subject (PROTOCOL §10.4), so it can
 * name a node that never claimed anything at all. Answer either question from the card alone and a vouch
 * about such a node is parsed, indexed, counted — and rendered nowhere, which hides it from the reader and
 * from the subject on their own profile, the one person `VOUCHED, NOT CLAIMED` exists to tell.
 */
object WorkSection {
    /** Is there a section here at all? No section mark and no "not set up yet" when there is not (§2.23). */
    fun present(work: WorkCard?, vouches: List<Vouch>): Boolean = work != null || vouches.isNotEmpty()

    /**
     * The tags only other people say. The subject must not be able to edit somebody else's sentence by
     * editing their own card, so a vouch whose tag is not in `work.does` keeps its own heading rather than
     * disappearing. Compared lowercased, like every §10.2 tag; first mention wins the spelling.
     */
    fun unclaimed(work: WorkCard?, vouches: List<Vouch>): List<String> {
        val claimed = work?.does.orEmpty().map { it.lowercase() }.toSet()
        return vouches.map { it.tag }.distinct().filter { it.lowercase() !in claimed }
    }
}

/**
 * PRODUCT §2.23 / §2.25 — the five strings that name the person being vouched for, in one place.
 *
 * They are here rather than inline in three files because PRODUCT §3 makes copy shared across the three
 * builds and these are the ones a build gets subtly wrong: the name is the subject's **first** name, the way
 * a sentence uses it — `Vouch for Ana`, not `Vouch for Ana Iliovic` and not `Vouch for @tgs_ana`. `name` is
 * `NodeSnapshot.firstName`, and null when the card carries no `name` at all, which every one of these words
 * differently rather than dropping a username into the middle of a sentence about a person.
 */
object VouchCopy {
    fun button(name: String?, username: String): String = "Vouch for ${name ?: "@$username"}"
    fun ask(name: String?): String = if (name != null) "Say one thing $name does." else "Say one thing they do."
    fun ownership(name: String?): String =
        "This goes in your comments channel, under your name. ${name ?: "They"} can't edit it or take it down."
    fun fieldLabel(name: String?): String = if (name != null) "What $name does" else "What they do"
    fun already(name: String?, tag: String): String = "You already vouched ${name ?: "them"} for $tag."
}

/**
 * PRODUCT §2.25 — the vouch modal. [chips] are the subject's own `work.does` in card order; `Something else`
 * reveals [customText], and a node that claims nothing shows only that, because you can vouch for someone
 * who has claimed nothing.
 *
 * [alreadyVouched] are the tags I have already vouched this person for. A second identical vouch is noise,
 * and the count it would inflate is not a count anyone should trust anyway (PROTOCOL §10.5).
 */
data class VouchUi(
    val subject: String = "",
    /**
     * The subject's first name, from the node's `name` (PRODUCT §2.25 writes `Say one thing Ana does.`).
     * Null when the card carries no `name`: every sentence built from it has a second wording for that,
     * because the app does not know a pronoun for anybody and a username is not one.
     */
    val subjectName: String? = null,
    /**
     * The `WHAT ANA DOES` label. Set from [subjectName]; a card with no `name` gets the generic form.
     */
    val fieldLabel: String = "What they do",
    val chips: List<String> = emptyList(),
    val selected: String? = null,
    val custom: Boolean = false,
    val customText: String = "",
    val body: String = "",
    val posting: Boolean = false,
    val alreadyVouched: Set<String> = emptySet(),
    val needsChannel: Boolean = false,
    val channelName: String = "",
    val channelAvailability: Availability = Availability.UNKNOWN,
    val channelNote: String = "",
    val creatingChannel: Boolean = false,
) {
    /** The one tag this vouch would carry, §10.2-normalised, or null while there is nothing to post. */
    val tag: String? get() = if (custom) WorkFormat.tag(customText) else selected

    /** A typed tag the grammar refuses — the inline faint line, and the button stays disabled (§2.25). */
    val customRefused: Boolean get() = custom && customText.isNotBlank() && WorkFormat.tag(customText) == null

    val canPost: Boolean get() = !posting && tag != null && tag !in alreadyVouched
}

/**
 * PRODUCT §2.15 — the report confirm. [reason] is null until a row is picked, which is exactly when
 * `Send Report` becomes tappable: an email whose subject line is blank helps nobody.
 */
data class ReportUi(val subject: ReportSubject? = null, val reason: String? = null) {
    val canSend: Boolean get() = subject != null && reason != null
}

/**
 * PRODUCT §2.21 — Delete my node. [input] is matched case-insensitively and tolerates a missing `@`;
 * [running] disables the button (`Deleting…`) and holds the modal open.
 *
 * [message] is the outcome the modal shows when Telegram refused. [openUsername] is set only for the
 * not-the-owner outcome, where the answer is in Telegram rather than in a retry — so it decides between
 * `( Open in Telegram )` and `( Try Again )`.
 */
data class DeleteNodeUi(
    val input: String = "",
    val running: Boolean = false,
    val message: String? = null,
    val openUsername: String? = null,
    /**
     * PRODUCT §2.21 — this run already destroyed the comments channel and the node refused. `Try Again` has
     * to remember it: PROTOCOL §4.11 step 2 rewrote the card without `replies:`, so nothing the retry can
     * read still says the channel existed, and it would report `Nothing was deleted.` over a channel it had
     * just deleted.
     */
    val commentsGone: Boolean = false,
)

/**
 * PRODUCT §2.12 — the comment composer. [needsChannel] shows the first-run `YOUR COMMENTS CHANNEL` card;
 * the composer proceeds once the channel exists.
 */
data class CommentComposerUi(
    val target: CommentTarget? = null,
    /** Where the quote's `×` re-aims: the post itself (§2.12). */
    val postTarget: CommentTarget? = null,
    val text: String = "",
    val photo: Uri? = null,
    val posting: Boolean = false,
    val needsChannel: Boolean = false,
    val channelName: String = "",
    val channelAvailability: Availability = Availability.UNKNOWN,
    val channelNote: String = "",
    val creatingChannel: Boolean = false,
)
