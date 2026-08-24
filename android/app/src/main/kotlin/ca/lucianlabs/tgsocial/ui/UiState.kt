package ca.lucianlabs.tgsocial.ui

import android.net.Uri
import ca.lucianlabs.tgsocial.model.Comment
import ca.lucianlabs.tgsocial.model.FeedCandidate
import ca.lucianlabs.tgsocial.model.FeedSource
import ca.lucianlabs.tgsocial.model.NodeEntry
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.model.Post

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
}

/** What a comment points at: a post or another comment. [title]/[excerpt] feed the composer's quote line. */
data class CommentTarget(val link: String, val title: String, val excerpt: String)

sealed class Sheet {
    data class Compose(val feedUsername: String?) : Sheet()
    data object EditCard : Sheet()
    data object SignOut : Sheet()
    /** PRODUCT §2.10 — the Status sheet, opened by tapping the status pill. */
    data object Status : Sheet()
    /** PRODUCT §2.12 — the comment composer. */
    data class CommentComposer(val target: CommentTarget) : Sheet()
    data class DeleteComment(val comment: Comment) : Sheet()
    /** PRODUCT §2.3 — the long-press post sheet: exact date, views, feed, and the one `Open in Telegram`. */
    data class PostSheet(val post: Post) : Sheet()
}

/** PRODUCT §2.11 — the full-screen viewer over one post's media, opened at [page]. */
data class ViewerUi(val post: Post, val page: Int)

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
)

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
)

data class ChannelUi(
    val username: String = "",
    val source: FeedSource? = null,
    val posts: List<Post> = emptyList(),
    val loading: Boolean = false,
    val cursor: Long? = null,
    val exhausted: Boolean = false,
    val verified: Boolean = false,
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
 * PRODUCT §2.12 — the comment composer. [needsChannel] shows the first-run `YOUR COMMENTS CHANNEL` card;
 * the composer proceeds once the channel exists.
 */
data class CommentComposerUi(
    val target: CommentTarget? = null,
    val text: String = "",
    val photo: Uri? = null,
    val posting: Boolean = false,
    val needsChannel: Boolean = false,
    val channelName: String = "",
    val channelAvailability: Availability = Availability.UNKNOWN,
    val channelNote: String = "",
    val creatingChannel: Boolean = false,
)
