package ca.lucianlabs.tgsocial.ui

import android.net.Uri
import ca.lucianlabs.tgsocial.model.Comment
import ca.lucianlabs.tgsocial.model.FeedCandidate
import ca.lucianlabs.tgsocial.model.FeedSource
import ca.lucianlabs.tgsocial.model.NodeEntry
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.protocol.CommentTarget
import ca.lucianlabs.tgsocial.protocol.ReportSubject
import ca.lucianlabs.tgsocial.protocol.SafetyFilter
import ca.lucianlabs.tgsocial.protocol.SafetyLists

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
)

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

data class EditCardUi(
    val name: String = "",
    val bio: String = "",
    val link: String = "",
    val saving: Boolean = false,
)

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
