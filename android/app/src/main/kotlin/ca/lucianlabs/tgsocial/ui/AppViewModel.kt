package ca.lucianlabs.tgsocial.ui

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import ca.lucianlabs.housepour.HPToastState
import ca.lucianlabs.housepour.HPToastTone
import ca.lucianlabs.tgsocial.BuildConfig
import ca.lucianlabs.tgsocial.TgApp
import ca.lucianlabs.tgsocial.demo.DemoCopy
import ca.lucianlabs.tgsocial.demo.DemoFiles
import ca.lucianlabs.tgsocial.demo.DemoGate
import ca.lucianlabs.tgsocial.demo.DemoRepo
import ca.lucianlabs.tgsocial.demo.DemoWorld
import ca.lucianlabs.tgsocial.model.Comment
import ca.lucianlabs.tgsocial.model.CommentNode
import ca.lucianlabs.tgsocial.model.FeedSource
import ca.lucianlabs.tgsocial.model.MyNode
import ca.lucianlabs.tgsocial.model.NodeEntry
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.model.SyncStatus
import ca.lucianlabs.tgsocial.protocol.Card
import ca.lucianlabs.tgsocial.protocol.CardFormat
import ca.lucianlabs.tgsocial.protocol.CommentFormat
import ca.lucianlabs.tgsocial.protocol.CommentTarget
import ca.lucianlabs.tgsocial.protocol.FeedOrder
import ca.lucianlabs.tgsocial.protocol.Replies
import ca.lucianlabs.tgsocial.protocol.ReplyTarget
import ca.lucianlabs.tgsocial.protocol.ReportEmail
import ca.lucianlabs.tgsocial.protocol.ReportMail
import ca.lucianlabs.tgsocial.protocol.ReportSubject
import ca.lucianlabs.tgsocial.protocol.SafetyFilter
import ca.lucianlabs.tgsocial.protocol.SafetyLists
import ca.lucianlabs.tgsocial.protocol.Username
import ca.lucianlabs.tgsocial.repo.ActivityRegistry
import ca.lucianlabs.tgsocial.repo.CardFullException
import ca.lucianlabs.tgsocial.repo.MyNodeRepo
import ca.lucianlabs.tgsocial.td.TdError
import dev.g000sha256.tdl.dto.AuthorizationStateClosed
import dev.g000sha256.tdl.dto.AuthorizationStateClosing
import dev.g000sha256.tdl.dto.AuthorizationStateLoggingOut
import dev.g000sha256.tdl.dto.AuthorizationStateReady
import dev.g000sha256.tdl.dto.AuthorizationStateWaitCode
import dev.g000sha256.tdl.dto.AuthorizationStateWaitOtherDeviceConfirmation
import dev.g000sha256.tdl.dto.AuthorizationStateWaitPassword
import dev.g000sha256.tdl.dto.AuthorizationStateWaitPhoneNumber
import dev.g000sha256.tdl.dto.AuthorizationStateWaitRegistration
import dev.g000sha256.tdl.dto.ConnectionState
import dev.g000sha256.tdl.dto.ConnectionStateConnecting
import dev.g000sha256.tdl.dto.ConnectionStateConnectingToProxy
import dev.g000sha256.tdl.dto.ConnectionStateReady
import dev.g000sha256.tdl.dto.ConnectionStateUpdating
import dev.g000sha256.tdl.dto.ConnectionStateWaitingForNetwork
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class AppViewModel(application: Application) : AndroidViewModel(application) {
    companion object {
        /** PRODUCT §6 — the version string the You footer shows. */
        val VERSION: String = "tgsocial ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})"

        /** PRODUCT §2.15 — the same string plus the platform, which is the report email's `App:` line. */
        val APP_VERSION: String = "$VERSION · Android"
    }

    private val app = application as TgApp
    private val tg get() = app.tg
    private val store get() = app.store
    private val nodes get() = app.nodes
    private val myNodeRepo get() = app.myNode
    private val feedRepo get() = app.feed
    private val commentRepo get() = app.comments
    private val discovery get() = app.discovery
    private val posting get() = app.posting

    val toast = HPToastState()

    // ---- auth
    private val _auth = MutableStateFlow(AuthUi())
    val auth: StateFlow<AuthUi> = _auth.asStateFlow()

    // ---- shell
    private val _tab = MutableStateFlow(Tab.FEED)
    val tab: StateFlow<Tab> = _tab.asStateFlow()
    private val _stack = MutableStateFlow<List<Screen>>(listOf(Screen.Home))
    val stack: StateFlow<List<Screen>> = _stack.asStateFlow()
    private val _sheet = MutableStateFlow<Sheet?>(null)
    val sheet: StateFlow<Sheet?> = _sheet.asStateFlow()
    private val _viewer = MutableStateFlow<ViewerUi?>(null)
    val viewer: StateFlow<ViewerUi?> = _viewer.asStateFlow()

    // ---- safety (PRODUCT §2.15–§2.18, PROTOCOL §7.1)
    /**
     * The reader's own block, mute and report lists. Every surface reads them through the `visible*` flows
     * below rather than filtering as it renders, so one list change repaints all of them and nothing has to
     * remember to ask.
     */
    private val _safety = MutableStateFlow(SafetyLists())
    val safety: StateFlow<SafetyLists> = _safety.asStateFlow()
    private val _report = MutableStateFlow(ReportUi())
    val report: StateFlow<ReportUi> = _report.asStateFlow()
    private val _deleteNode = MutableStateFlow(DeleteNodeUi())
    val deleteNode: StateFlow<DeleteNodeUi> = _deleteNode.asStateFlow()

    // ---- the demo (PRODUCT §2.22)
    /**
     * The demo session, or null. §2.22.4 — the demo is a **different object, not a mode**: `DemoRepo` holds the
     * whole invented world and no reference to the TDLib client, and every entry point below that would have
     * reached Telegram returns early into it. A boolean checked at each call site has branches that can be
     * missed; the object has no code path to Telegram to miss in the first place, and what is left here is the
     * short list of doors into it.
     */
    private val _demo = MutableStateFlow<DemoRepo?>(null)
    val demo: StateFlow<DemoRepo?> = _demo.asStateFlow()

    val inDemo: Boolean get() = _demo.value != null

    /** True from the tap on `Look Around First` until the demo actually opens — see [enterDemo]. */
    private var enteringDemo = false

    /**
     * PROTOCOL §7.1 — the reader's real record, held aside for the length of the demo. A demo session must not
     * load it (a real block list is not a demo's to browse) and must not overwrite it on the way out.
     */
    private var storedSafety: SafetyLists? = null

    /** The demo's comment index and card cache, which shadow the real ones for as long as it runs. */
    private val _demoComments = MutableStateFlow<Map<String, List<Comment>>?>(null)
    private val _demoCards = MutableStateFlow<Map<String, NodeSnapshot>?>(null)

    // ---- status (PRODUCT §2.10)
    /** The live list of in-flight operations; the Status sheet's `Pending` rows. */
    val pending: StateFlow<List<ActivityRegistry.Entry>> get() = app.activity.entries
    val lastError: StateFlow<ActivityRegistry.LastError?> get() = app.activity.lastError
    val connection: StateFlow<ConnectionState?> get() = tg.connection
    private val _phone = MutableStateFlow("")
    val phone: StateFlow<String> = _phone.asStateFlow()
    val tdlibVersion: String get() = tg.tdlibVersion

    /**
     * The status pill, derived — never counted. PRODUCT §2.10 assigns three states: `Syncing` exactly while the
     * activity registry is non-empty (every entry clears on success, failure, cancellation, or a 30 s timeout, so
     * a stuck `Syncing` is impossible by construction), `Synced` when it is empty and the connection is
     * `Connected`, `Offline` while TDLib waits for network. The connection states the spec leaves unassigned map
     * as follows: before a connection exists (`Connecting`, `Connecting to proxy`, or no state yet) the pill reads
     * `Syncing` — `Synced` would be untrue — and these resolve or fall to waiting-for-network on their own;
     * `Updating` reads `Synced` when the registry is empty, because TDLib is connected and applying its own
     * unbounded diff — the sheet's Connection row says `Updating`, and nothing the app started is unattributed.
     */
    val status: StateFlow<SyncStatus> = combine(tg.connection, app.activity.entries, _auth) { conn, inFlight, a ->
        when {
            a.step != AuthStep.READY -> SyncStatus.SIGNED_OUT
            conn is ConnectionStateWaitingForNetwork -> SyncStatus.OFFLINE
            inFlight.isNotEmpty() -> SyncStatus.SYNCING
            conn == null || conn is ConnectionStateConnecting || conn is ConnectionStateConnectingToProxy -> SyncStatus.SYNCING
            else -> SyncStatus.SYNCED
        }
    }.stateIn(viewModelScope, SharingStarted.Eagerly, SyncStatus.SIGNED_OUT)

    /** PRODUCT §2.10 — `Connection` mirrors TDLib `updateConnectionState`. */
    fun connectionLabel(conn: ConnectionState?): String = when (conn) {
        is ConnectionStateReady -> "Connected"
        is ConnectionStateConnecting, null -> "Connecting"
        is ConnectionStateConnectingToProxy -> "Connecting to proxy"
        is ConnectionStateUpdating -> "Updating"
        is ConnectionStateWaitingForNetwork -> "Waiting for network"
        else -> "Connecting"
    }

    // ---- my node
    private val _myNode = MutableStateFlow<MyNode?>(null)
    val myNode: StateFlow<MyNode?> = _myNode.asStateFlow()
    private val _me = MutableStateFlow<NodeSnapshot?>(null)
    val me: StateFlow<NodeSnapshot?> = _me.asStateFlow()
    val myCard: Card? get() = _me.value?.card
    private val _setupNeeded = MutableStateFlow(false)
    val setupNeeded: StateFlow<Boolean> = _setupNeeded.asStateFlow()
    private val _nodeSearched = MutableStateFlow(false)

    // ---- screens
    private val _feed = MutableStateFlow(FeedUi())
    val feed: StateFlow<FeedUi> = _feed.asStateFlow()
    private val _explore = MutableStateFlow(ExploreUi())
    val explore: StateFlow<ExploreUi> = _explore.asStateFlow()
    private val _graph = MutableStateFlow(GraphUi())
    val graph: StateFlow<GraphUi> = _graph.asStateFlow()
    private val _profile = MutableStateFlow(ProfileUi())
    val profile: StateFlow<ProfileUi> = _profile.asStateFlow()
    private val _channel = MutableStateFlow(ChannelUi())
    val channel: StateFlow<ChannelUi> = _channel.asStateFlow()
    private val _setup = MutableStateFlow(SetupUi())
    val setup: StateFlow<SetupUi> = _setup.asStateFlow()
    private val _compose = MutableStateFlow(ComposeUi())
    val compose: StateFlow<ComposeUi> = _compose.asStateFlow()
    private val _editCard = MutableStateFlow(EditCardUi())
    val editCard: StateFlow<EditCardUi> = _editCard.asStateFlow()
    private val _commentComposer = MutableStateFlow(CommentComposerUi())
    val commentComposer: StateFlow<CommentComposerUi> = _commentComposer.asStateFlow()

    /**
     * Every surface that resolves a username to a name or a photo reads this. In the demo it is the fixture
     * world's own map, so Settings rows, the graph radial and the blocked-node card name invented people
     * without `NodeRepo` ever being asked — and without a demo card reaching the disk cache.
     */
    val cards: StateFlow<Map<String, NodeSnapshot>> = combine(nodes.cards, _demoCards) { real, demo ->
        demo ?: real
    }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyMap())

    // ---- the default filter (PRODUCT §2.18)
    //
    // Filtered *views* of the state, never filtered state: `_feed`, `_channel` and the comment index keep
    // everything they loaded, so an `Unblock` in Settings repaints the next frame instead of waiting for a
    // refresh to fetch the same posts again.

    /** The main feed: blocked nodes, reported posts, and — here only — muted feeds are gone (§2.17). */
    val visibleFeed: StateFlow<FeedUi> = combine(_feed, _safety) { f, s ->
        f.filtered(s)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, FeedUi())

    /** A feed channel's own screen stays complete when muted; blocked and reported still drop (§2.17). */
    val visibleChannel: StateFlow<ChannelUi> = combine(_channel, _safety) { c, s ->
        c.copy(posts = SafetyFilter.posts(c.posts, s, mainFeed = false), muted = s.isMuted(c.username))
    }.stateIn(viewModelScope, SharingStarted.Eagerly, ChannelUi())

    val visibleExplore: StateFlow<ExploreUi> = combine(_explore, _safety) { e, s ->
        e.copy(nearby = SafetyFilter.nodes(e.nearby, s), directory = SafetyFilter.nodes(e.directory, s))
    }.stateIn(viewModelScope, SharingStarted.Eagerly, ExploreUi())

    /** §2.18 — a blocked node is not in `DIRECT · 12` or `+1 · 84`; the counts are these lists' sizes. */
    val visibleGraph: StateFlow<GraphUi> = combine(_graph, _safety) { g, s ->
        g.copy(direct = SafetyFilter.nodes(g.direct, s), plusOne = SafetyFilter.nodes(g.plusOne, s))
    }.stateIn(viewModelScope, SharingStarted.Eagerly, GraphUi())

    val visibleProfile: StateFlow<ProfileUi> = combine(_profile, _safety) { p, s ->
        p.copy(blocked = s.isBlocked(p.username))
    }.stateIn(viewModelScope, SharingStarted.Eagerly, ProfileUi())

    // ---- comments (PRODUCT §2.12)
    /**
     * The comment index every surface reads — filtered (§2.18). Counts and trees derive from this map, so a
     * blocked commenter leaves no residue in `N comments` and takes the replies under them with them.
     */
    val commentIndex: StateFlow<Map<String, List<Comment>>> = combine(commentRepo.index, _demoComments, _safety) { index, demo, s ->
        SafetyFilter.comments(demo ?: index, s)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyMap())

    fun postTargetKey(post: Post): String = CommentFormat.postKey(post.sourceUsername, post.messageId)
    fun commentCount(post: Post, index: Map<String, List<Comment>>): Int = commentRepo.countFor(postTargetKey(post), index)
    fun commentTree(post: Post, index: Map<String, List<Comment>>): List<CommentNode> = commentRepo.tree(postTargetKey(post), index)

    private var bootstrapped = false
    private var feedJob: Job? = null
    private var availabilityJob: Job? = null
    private var replyChannelJob: Job? = null
    private var candidatesJob: Job? = null
    private var candidateRefreshJob: Job? = null

    init {
        viewModelScope.launch { tg.authState.collect { onAuth(it) } }
        viewModelScope.launch {
            tg.floodWaits.collect {
                app.activity.recordError("FLOOD_WAIT ${it.seconds} s")
                toast.show("Telegram asked us to wait ${it.seconds} s.", HPToastTone.BAD)
            }
        }
        viewModelScope.launch {
            tg.newMessages.collect { m ->
                if (!bootstrapped || m.isOutgoing && m.sendingState != null) return@collect
                val post = runCatching { feedRepo.liveToPost(m) }.getOrNull() ?: return@collect
                // Live inserts land at the top — the list stays strictly newest first (PRODUCT §2.3). Deep into
                // a paginated session the window is full and anchored at its tail (the merge cursor), so a post
                // newer than the head has no room: flag it for the `Newer posts` jump instead of letting the
                // trim swallow it or punching a hole in the pagination (FeedOrder.window).
                _feed.update { f ->
                    if (FeedOrder.isAboveFullWindow(f.posts, post)) f.copy(newerAvailable = true)
                    else f.copy(posts = FeedOrder.insertLive(f.posts, post))
                }
            }
        }
        viewModelScope.launch {
            // PRODUCT §2.2 — a channel made public (or created, or admin-granted) while Setup / Manage feeds is
            // on screen appears without any user action: candidacy-changing TDLib updates schedule a debounced
            // live re-query. Never on a timer; only on these updates, and only while the surface is visible.
            tg.candidateChanges.collect { scheduleCandidateRefresh() }
        }
        tg.onClosed += { viewModelScope.launch { wipeLocal() } }
    }

    // ------------------------------------------------------------------ auth

    private suspend fun onAuth(state: dev.g000sha256.tdl.dto.AuthorizationState?) {
        when (state) {
            null -> _auth.update { it.copy(step = AuthStep.LOADING, busy = false) }
            is AuthorizationStateWaitPhoneNumber -> _auth.update { it.copy(step = AuthStep.PHONE, busy = false, qrLink = null) }
            is AuthorizationStateWaitCode -> _auth.update { it.copy(step = AuthStep.CODE, busy = false) }
            is AuthorizationStateWaitPassword -> _auth.update { it.copy(step = AuthStep.PASSWORD, passwordHint = state.passwordHint, busy = false) }
            is AuthorizationStateWaitOtherDeviceConfirmation -> _auth.update { it.copy(step = AuthStep.OTHER_DEVICE, qrLink = state.link, busy = false) }
            is AuthorizationStateWaitRegistration -> _auth.update { it.copy(step = AuthStep.REGISTRATION, busy = false) }
            is AuthorizationStateReady -> {
                _auth.update { it.copy(step = AuthStep.READY, busy = false) }
                bootstrap()
            }
            is AuthorizationStateLoggingOut, is AuthorizationStateClosing, is AuthorizationStateClosed ->
                _auth.update { it.copy(step = AuthStep.LOADING, busy = true) }
            else -> Unit
        }
    }

    private fun authCall(block: suspend () -> Any?) {
        _auth.update { it.copy(busy = true) }
        viewModelScope.launch {
            try {
                block()
            } catch (e: TdError) {
                _auth.update { it.copy(busy = false) }
                app.activity.recordError(e.message)
                toast.show(authErrorCopy(e), HPToastTone.BAD)
            } catch (e: TimeoutCancellationException) {
                _auth.update { it.copy(busy = false) }
                toast.show(errorCopy(e), HPToastTone.BAD)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _auth.update { it.copy(busy = false) }
                toast.show(e.message ?: "Something went wrong.", HPToastTone.BAD)
            }
        }
    }

    private fun authErrorCopy(e: TdError): String {
        val m = e.message
        return when {
            e.floodWaitSeconds != null -> "Too many tries. Wait ${e.floodWaitSeconds} s."
            e.code == 429 -> "Too many tries. Wait a moment."
            m.contains("PHONE_CODE_INVALID", true) || m.contains("code", true) && m.contains("invalid", true) -> "That code didn't match."
            m.contains("PASSWORD_HASH_INVALID", true) || m.contains("password", true) && m.contains("invalid", true) -> "That password didn't match."
            m.contains("PHONE_NUMBER_INVALID", true) || m.contains("PHONE_NUMBER_BANNED", true) -> "Telegram didn't accept that number."
            else -> m
        }
    }

    fun sendPhone(phone: String) = authCall { tg.call { setAuthenticationPhoneNumber(phoneNumber = phone.trim(), settings = null) } }
    fun sendCode(code: String) = authCall { tg.call { checkAuthenticationCode(code = code.trim()) } }
    fun sendPassword(password: String) = authCall { tg.call { checkAuthenticationPassword(password = password) } }

    /** `Use another number`: TDLib accepts a new setAuthenticationPhoneNumber from the code step, so just show the phone step. */
    fun useAnotherNumber() { _auth.update { it.copy(step = AuthStep.PHONE, busy = false) } }

    // ------------------------------------------------------------------ the demo (PRODUCT §2.22)

    /**
     * `Look Around First` (§2.1 step 1). The button is on the phone step, so nothing is in flight when it is
     * tapped, and everything below is built from [DemoWorld].
     *
     * §2.22.4 — TDLib goes quiet **and says so** before any of it happens. The call is awaited rather than
     * launched and forgotten, because the demo's first fixture painting over a live socket is exactly the
     * window a reviewer's proxy is pointed at; it is answered locally, so the wait is not perceptible. The
     * guard is a field rather than [inDemo] because [inDemo] is not true yet during that wait, and a second
     * tap would otherwise start a second session.
     */
    fun enterDemo() {
        if (inDemo || enteringDemo) return
        enteringDemo = true
        viewModelScope.launch {
            tg.setNetworkAvailable(false)
            enteringDemo = false
            if (!inDemo) openDemo()
        }
    }

    private fun openDemo() {
        val session = DemoRepo()
        DemoFiles.attach(app.applicationContext.cacheDir)
        // §2.22.3 — `Open in Telegram`, `Copy Link`, `Share` and every link answer with their own line.
        DemoGate.open { message -> toast.show(message, HPToastTone.NEUTRAL) }
        // PROTOCOL §7.1 — the real record steps aside; the demo starts with empty lists of its own.
        storedSafety = _safety.value
        _safety.value = session.safety
        _demo.value = session
        _demoCards.value = session.cards
        _demoComments.value = session.comments
        _myNode.value = session.myNode
        _me.value = session.me
        _phone.value = ""
        _setupNeeded.value = false
        _nodeSearched.value = true
        _tab.value = Tab.FEED
        _stack.value = listOf(Screen.Home)
        _sheet.value = null
        _viewer.value = null
        loadDemoFeed(session, reset = true)
    }

    /**
     * `Leave Demo` — from the demo sheet, from Settings, and from the demo's own `Delete My Node`. §2.22.5:
     * there is no cleanup step to get wrong, because nothing about the demo was written to disk; the object is
     * dropped and the real record comes back exactly as it was written.
     */
    fun leaveDemo(toastText: String? = DemoCopy.LEFT) {
        if (!inDemo) return
        DemoGate.close()
        DemoFiles.detach()
        // Restoring it is not urgent the way silencing it was: nothing may go out until this lands, and
        // everything after this point is local state.
        viewModelScope.launch { tg.setNetworkAvailable(true) }
        _demo.value = null
        _demoCards.value = null
        _demoComments.value = null
        _safety.value = storedSafety ?: SafetyLists()
        storedSafety = null
        _myNode.value = null
        _me.value = null
        _phone.value = ""
        _feed.value = FeedUi()
        _explore.value = ExploreUi()
        _graph.value = GraphUi()
        _profile.value = ProfileUi()
        _channel.value = ChannelUi()
        _report.value = ReportUi()
        _deleteNode.value = DeleteNodeUi()
        _stack.value = listOf(Screen.Home)
        _sheet.value = null
        _viewer.value = null
        _tab.value = Tab.FEED
        app.playback.stopAudio()
        // §2.22 — back to §2.1 step 1, with the phone field empty. The field is composable-local state on a
        // screen that leaves the composition with the shell, so it comes back blank without being cleared.
        _auth.update { it.copy(step = AuthStep.PHONE, busy = false, qrLink = null) }
        toastText?.let { toast.show(it, HPToastTone.GOOD) }
    }

    /**
     * PRODUCT §2.22.3 — every write answers with one toast and does nothing. Nothing is greyed out: a disabled
     * button teaches nothing and reads as a broken app, so the control stays where it is, stays tappable, and
     * names the boundary.
     */
    private fun demoRefusesWrite(): Boolean {
        if (!inDemo) return false
        toast.show(DemoCopy.NO_WRITE, HPToastTone.NEUTRAL)
        return true
    }

    private fun loadDemoFeed(session: DemoRepo, reset: Boolean) {
        if (reset) session.resetFeed()
        val page = session.feedPage()
        _feed.update {
            val posts = if (reset) page else FeedOrder.append(it.posts, page)
            it.copy(
                posts = FeedOrder.sort(posts),
                loading = false,
                refreshing = false,
                exhausted = session.feedExhausted,
                sourceCount = session.sourceCount,
                ready = true,
                refreshedAt = System.currentTimeMillis(),
                newerAvailable = false,
            )
        }
    }

    // ------------------------------------------------------------------ bootstrap

    private fun bootstrap() {
        if (bootstrapped) return
        bootstrapped = true
        viewModelScope.launch {
            // PRODUCT §2.18 — the filter is on and there is no switch, which includes the first frame. The
            // lists come off disk first, before anything paints: they are local state (PROTOCOL §7.1) and
            // nothing about reading them needs Telegram, so nothing about them may wait on Telegram. Behind
            // `myNodeRepo.me()` — a request TelegramClient bounds at 40 s — a degraded network meant the
            // cached feed painted blocked nodes and reported posts for as long as that call took to give up.
            restoreSafety()
            nodes.restore()
            _tab.value = Tab.entries[store.lastTab().coerceIn(0, Tab.entries.lastIndex)]
            // Cold start: the last cached feed first, never a blank screen behind a spinner.
            val cached = feedRepo.cachedFeed()
            if (cached.isNotEmpty()) _feed.update { it.copy(posts = FeedOrder.sort(cached), ready = true) }
            val account = runCatching { myNodeRepo.me() }.getOrNull()
            _phone.value = account?.phoneNumber.orEmpty()
            adoptSafetyAccount(account?.id)
            val pointer = store.myNode()
            if (pointer != null) {
                _myNode.value = pointer
                val snap = runCatching { nodes.fetch(pointer.username) }.getOrNull() ?: nodes.cached(pointer.username)
                // A card newer than this app understands is still my node (PROTOCOL §8): keep it, refuse writes.
                if (snap?.card != null || snap?.newerVersion == true) _me.value = snap
                else if (snap != null) {
                    // Pointer stale: the pin is gone. Search again.
                    findMyNode(quiet = true)
                }
            } else {
                findMyNode(quiet = true)
            }
            _nodeSearched.value = true
            if (_me.value == null && !store.setupSkipped()) {
                _setupNeeded.value = true
                prepareSetup()
            }
            refreshFeed(resetCursors = true)
        }
    }

    private suspend fun findMyNode(quiet: Boolean): Boolean {
        val found = runCatching { myNodeRepo.find() }.onFailure { if (!quiet) fail(it) }.getOrNull()
        if (found != null) {
            _myNode.value = found.first
            _me.value = found.second
            // Setup stays up (when it is up) so Card 2 can show the feeds of the node just found; saveFeeds()/skipSetup() exit.
            if (found.second.newerVersion && !quiet) toast.show("Newer card. Update the app.", HPToastTone.BAD)
            return true
        }
        return false
    }

    private fun errorCopy(t: Throwable): String = when (t) {
        is CardFullException -> "Card is full."
        is TdError -> when {
            t.floodWaitSeconds != null -> "Telegram asked us to wait ${t.floodWaitSeconds} s."
            t.isOffline || t.message.contains("Network", true) -> "You're offline."
            else -> t.message
        }
        is TimeoutCancellationException -> if (tg.isOffline) "You're offline." else "Telegram didn't answer. Try again."
        else -> t.message ?: "Something went wrong."
    }

    /** Toast the failure and record it as the Status sheet's `Last error` (PRODUCT §2.10). */
    private fun fail(t: Throwable) {
        when (t) {
            is TdError -> app.activity.recordError(t.floodWaitSeconds?.let { "FLOOD_WAIT $it s" } ?: t.message)
            is TimeoutCancellationException -> app.activity.recordError("Request timed out")
            else -> app.activity.recordError(t.message ?: t.javaClass.simpleName)
        }
        toast.show(errorCopy(t), HPToastTone.BAD)
    }

    /** A real cancellation (job cancelled, screen gone) — not a request timeout, which is a failure the user should see. */
    private fun isCancelled(t: Throwable): Boolean = t is CancellationException && t !is TimeoutCancellationException

    /** Offline reads serve cache silently (PRODUCT §4); anything else gets a toast. */
    private fun isQuietOffline(t: Throwable): Boolean =
        (t is TdError && t.isOffline) || (t is TimeoutCancellationException && tg.isOffline)

    /** My card, or a toast saying why there is none: no node yet, or a card newer than this app understands. */
    private fun cardOrToast(): Card? {
        myCard?.let { return it }
        toast.show(if (_me.value?.newerVersion == true) "Newer card. Update the app." else "Make your node first.", HPToastTone.BAD)
        return null
    }

    // ------------------------------------------------------------------ navigation

    fun selectTab(t: Tab) {
        // The floating tab bar stays on pushed screens; picking a tab returns to the root of that tab.
        if (_stack.value.size > 1) _stack.value = listOf(Screen.Home)
        _tab.value = t
        viewModelScope.launch { store.saveLastTab(t.ordinal) }
        when (t) {
            Tab.EXPLORE -> if (!_explore.value.loaded) loadExplore()
            Tab.GRAPH -> if (!_graph.value.loaded) loadGraph()
            else -> Unit
        }
    }

    fun push(screen: Screen) {
        _stack.update { it + screen }
        when (screen) {
            is Screen.Profile -> loadProfile(screen.username)
            is Screen.FeedChannel -> loadChannel(screen.username)
            is Screen.Setup, is Screen.ManageFeeds -> prepareSetup()
            is Screen.Thread -> refreshComments(force = true)
            else -> Unit
        }
    }

    /** PRODUCT §2.12 — tapping the text or the comments count opens the thread. */
    fun openThread(post: Post) {
        // A target selected in one thread has no meaning in another; arriving at a thread aims at the post.
        clearReplyTarget()
        push(Screen.Thread(post))
    }

    /** Returns false when there was nothing to pop (let the system handle back). */
    fun back(): Boolean {
        // Innermost first. The comment composer can now be opened from ON TOP of the viewer (§2.12), so the
        // sheet has to come before it; comments over the media are then a layer of their own, and back closes
        // them and leaves the media up.
        if (_sheet.value != null) { closeSheet(); return true }
        if (_viewer.value?.commentsOpen == true) { toggleViewerComments(); return true }
        if (_viewer.value != null) { closeViewer(); return true }
        if (_stack.value.size > 1) {
            _stack.update { it.dropLast(1) }
            reloadTop()
            return true
        }
        return false
    }

    /** The pushed-screen state is single-slot; whatever is now on top has to be reloaded into it. */
    private fun reloadTop() {
        when (val top = _stack.value.last()) {
            is Screen.Profile -> loadProfile(top.username)
            is Screen.FeedChannel -> loadChannel(top.username)
            else -> Unit
        }
    }

    /**
     * PRODUCT §2.18 — a post that has just landed on a safety list takes its own Thread screen with it. The
     * thread *is* the post: §2.15's toast says it is hidden here now, and §2.16 promises a blocked node's
     * posts leave "your feed, your threads, your graph, and search". Leaving the card painted under the toast
     * makes both of those untrue, and the comment tree below it hangs off a post that is gone.
     *
     * Not [back]: back closes the innermost layer, which on this path could be a viewer opened over the same
     * post's media, and the thread would survive underneath it.
     */
    fun dismissThread(post: Post) {
        val stack = _stack.value
        val next = stack.filterNot { it is Screen.Thread && it.post.key == post.key }
        if (next.size == stack.size || next.isEmpty()) return
        _stack.value = next
        reloadTop()
    }

    fun openSheet(s: Sheet) {
        when (s) {
            is Sheet.Compose -> prepareCompose(s.feedUsername)
            Sheet.EditCard -> _editCard.value = EditCardUi(name = myCard?.name.orEmpty(), bio = myCard?.bio.orEmpty(), link = myCard?.link.orEmpty())
            is Sheet.CommentComposer -> prepareCommentComposer(s.post, s.target)
            // PRODUCT §2.21 — the field opens empty every time; a typed username is not a standing permission.
            Sheet.DeleteNode -> _deleteNode.value = DeleteNodeUi()
            Sheet.SignOut, Sheet.Status, Sheet.Demo, Sheet.Report, is Sheet.Block,
            is Sheet.DeleteComment, is Sheet.PostSheet, is Sheet.CommentSheet,
            -> Unit
        }
        _sheet.value = s
    }

    fun closeSheet() {
        if (_sheet.value is Sheet.Compose && _compose.value.posting) return
        if (_sheet.value is Sheet.CommentComposer && _commentComposer.value.posting) return
        // PRODUCT §2.21 — while the delete runs the modal cannot be dismissed.
        if (_sheet.value is Sheet.DeleteNode && _deleteNode.value.running) return
        _sheet.value = null
    }

    // ------------------------------------------------------------------ viewer (PRODUCT §2.11)

    fun openViewer(post: Post, page: Int) {
        clearReplyTarget()
        _viewer.value = ViewerUi(post, page)
    }

    fun closeViewer() {
        _viewer.value = null
    }

    /** PRODUCT §2.12 — paging the carousel moves the mini view and re-targets the thread to that item's post. */
    fun setViewerPage(page: Int) {
        _viewer.update { it?.copy(page = page) }
    }

    /**
     * PRODUCT §2.12 — the viewer's `Comments` control, and the mini view's tap back to full screen. Opening
     * refreshes the index for the visible target, exactly as the Thread screen does when it is pushed.
     */
    fun toggleViewerComments() {
        val next = _viewer.value?.let { it.copy(commentsOpen = !it.commentsOpen) } ?: return
        _viewer.value = next
        if (next.commentsOpen) refreshComments()
    }

    // ------------------------------------------------------------------ feed

    fun refreshFeed(resetCursors: Boolean = true) {
        _demo.value?.let { loadDemoFeed(it, reset = true); return }
        feedJob?.cancel()
        feedJob = viewModelScope.launch {
            _feed.update { it.copy(refreshing = true, loading = true) }
            runCatching {
                // Refresh my card and the cards of my follows so new feeds show up. Offline: reads serve cache.
                if (!tg.isOffline) _myNode.value?.let { n -> runCatching { nodes.fetch(n.username) }.getOrNull()?.let { if (it.card != null) _me.value = it } }
                val sources = feedRepo.resolveSources(_myNode.value?.username, myCard, fresh = resetCursors)
                if (resetCursors) feedRepo.reset()
                val posts = FeedOrder.sort(feedRepo.loadMore(20))
                // A completed refresh rebuilds the window from the newest post down, so whatever was waiting
                // above the old window is now in the list — the `Newer posts` jump has done its job.
                _feed.update {
                    it.copy(
                        posts = posts,
                        exhausted = feedRepo.exhausted,
                        sourceCount = sources.size,
                        ready = true,
                        refreshedAt = System.currentTimeMillis(),
                        newerAvailable = false,
                    )
                }
                if (posts.isNotEmpty()) feedRepo.cacheFeed(posts)
                nodes.persist()
            }.onFailure { e ->
                if (!isCancelled(e)) {
                    _feed.update { it.copy(ready = true) }
                    if (!isQuietOffline(e)) fail(e)
                }
            }
            _feed.update { it.copy(refreshing = false, loading = false) }
            // The comment index refreshes alongside the feed (PROTOCOL §6.3).
            runCatching { commentRepo.refresh(_myNode.value?.username, myCard) }
        }
    }

    fun loadMoreFeed() {
        val f = _feed.value
        if (f.loading || f.exhausted || !f.ready) return
        // §2.22.1 pages eight at a time, so this runs for real: a second page, then `That's everything.`
        _demo.value?.let { loadDemoFeed(it, reset = false); return }
        feedJob = viewModelScope.launch {
            _feed.update { it.copy(loading = true) }
            runCatching { feedRepo.loadMore(20) }
                // Load-more appends older posts below; order is re-asserted (PRODUCT §2.3).
                .onSuccess { more -> _feed.update { it.copy(posts = FeedOrder.append(it.posts, more), exhausted = feedRepo.exhausted) } }
                .onFailure { e -> if (!isCancelled(e) && !isQuietOffline(e)) fail(e) }
            _feed.update { it.copy(loading = false) }
        }
    }

    // ------------------------------------------------------------------ comments (PRODUCT §2.12 / PROTOCOL §6)

    private val _commentsRefreshing = MutableStateFlow(false)
    val commentsRefreshing: StateFlow<Boolean> = _commentsRefreshing.asStateFlow()

    fun refreshComments(force: Boolean = false) {
        // The demo's index is the whole of its comments and never changes; there is nothing to re-scan.
        if (inDemo) return
        viewModelScope.launch {
            _commentsRefreshing.value = true
            try {
                runCatching { commentRepo.refresh(_myNode.value?.username, myCard, force = force) }
            } finally {
                _commentsRefreshing.value = false
            }
        }
    }

    fun targetForPost(post: Post): CommentTarget = ReplyTarget.forPost(post)

    fun targetForComment(comment: Comment): CommentTarget = ReplyTarget.forComment(comment)

    // ---- reply target (PRODUCT §2.12): tapping a comment aims the next reply at it

    private val _replyTarget = MutableStateFlow<CommentTarget?>(null)

    /**
     * The comment the next reply points at, or null for the post — §2.12's `re:` chain made direct. It is
     * one selection, not one per screen, because the carousel's comments and the Thread screen are the same
     * thread: closing one over the media and opening the other must not change who you were replying to.
     */
    val replyTarget: StateFlow<CommentTarget?> = _replyTarget.asStateFlow()

    /** A tap on a comment row: select it, or clear it if it was already the target (§2.12). */
    fun toggleReplyTarget(comment: Comment) {
        _replyTarget.value = ReplyTarget.toggle(_replyTarget.value, ReplyTarget.forComment(comment))
    }

    /** The quote's `×`, and every place a thread stops being the one on screen. */
    fun clearReplyTarget() {
        _replyTarget.value = null
    }

    /** What `( Comment )` sends against: the selected comment, else the post itself. */
    fun composerTarget(post: Post): CommentTarget = ReplyTarget.resolve(_replyTarget.value, post)

    /** `( Comment )` — against the selected comment if there is one, else against the post (§2.12). */
    fun openCommentComposer(post: Post) = openSheet(Sheet.CommentComposer(post, composerTarget(post)))

    /** `Reply` on a comment row: select it, then open the composer aimed at it. */
    fun replyToComment(post: Post, comment: Comment) {
        val target = ReplyTarget.forComment(comment)
        _replyTarget.value = target
        openSheet(Sheet.CommentComposer(post, target))
    }

    private fun prepareCommentComposer(post: Post, target: CommentTarget) {
        val needsChannel = myCard != null && myCard?.replies == null
        val suggested = _myNode.value?.username?.let { Replies.convention(it) }.orEmpty()
        _commentComposer.value = CommentComposerUi(
            target = target,
            postTarget = ReplyTarget.forPost(post),
            needsChannel = needsChannel,
            channelName = suggested,
        )
        if (needsChannel && suggested.isNotEmpty()) checkReplyChannelName()
    }

    /**
     * PRODUCT §2.12 — the quote's `×`: the reply goes to the post instead. It clears the selection behind the
     * composer too, so the thread underneath stops showing a target the reader has just dismissed.
     */
    fun clearComposerTarget() {
        clearReplyTarget()
        _commentComposer.update { it.copy(target = it.postTarget ?: it.target) }
    }

    fun setCommentText(t: String) { _commentComposer.update { it.copy(text = t) } }
    fun setCommentPhoto(uri: Uri?) { _commentComposer.update { it.copy(photo = uri) } }

    fun setReplyChannelName(name: String) {
        if (inDemo) return
        _commentComposer.update { it.copy(channelName = name.trim(), channelAvailability = Availability.UNKNOWN) }
        checkReplyChannelName()
    }

    private fun checkReplyChannelName() {
        replyChannelJob?.cancel()
        replyChannelJob = viewModelScope.launch {
            delay(450)
            val name = _commentComposer.value.channelName
            if (Username.normalise(name) != name || name.isEmpty()) {
                _commentComposer.update { it.copy(channelAvailability = Availability.TAKEN, channelNote = "Invalid") }
                return@launch
            }
            _commentComposer.update { it.copy(channelAvailability = Availability.CHECKING) }
            val r = runCatching { myNodeRepo.checkUsername(name, 0L) }.getOrNull()
            _commentComposer.update {
                when (r) {
                    is MyNodeRepo.Availability.Available -> it.copy(channelAvailability = Availability.AVAILABLE, channelNote = "")
                    is MyNodeRepo.Availability.Taken -> it.copy(channelAvailability = Availability.TAKEN, channelNote = r.reason)
                    null -> it.copy(channelAvailability = Availability.UNKNOWN)
                }
            }
        }
    }

    /** PRODUCT §2.12 first run — `( Make Channel )`: §6.4, then the composer proceeds. */
    fun makeRepliesChannel() {
        if (demoRefusesWrite()) return
        val node = _myNode.value ?: return
        val card = cardOrToast() ?: return
        val name = _commentComposer.value.channelName
        if (Username.normalise(name) != name || name.isEmpty()) { toast.show("That name isn't allowed.", HPToastTone.BAD); return }
        if (tg.isOffline) { toast.show("You're offline.", HPToastTone.BAD); return }
        viewModelScope.launch {
            _commentComposer.update { it.copy(creatingChannel = true) }
            runCatching { myNodeRepo.createRepliesChannel(node, card, name) }
                .onSuccess { (updated, next) ->
                    _myNode.value = updated
                    _me.value = _me.value?.copy(card = next)
                    nodes.persist()
                    _commentComposer.update { it.copy(needsChannel = false, creatingChannel = false) }
                }
                .onFailure { e ->
                    _commentComposer.update { it.copy(creatingChannel = false) }
                    fail(e)
                }
        }
    }

    /** PRODUCT §2.12 — optimistic posting: the comment appears immediately, then settles or rolls back. */
    fun postComment() {
        if (demoRefusesWrite()) return
        val c = _commentComposer.value
        val target = c.target ?: return
        val me = _me.value ?: run { toast.show("Make your node first.", HPToastTone.BAD); return }
        val repliesChannel = myCard?.replies ?: run { toast.show("Make your comments channel first.", HPToastTone.BAD); return }
        if (c.text.isBlank() && c.photo == null) return
        if (tg.isOffline) { toast.show("You're offline.", HPToastTone.BAD); return }
        val targetKey = CommentFormat.targetKey(target.link) ?: return
        val body = c.text.trim()
        val optimistic = Comment(
            chatId = 0L,
            messageId = -System.currentTimeMillis(),
            date = (System.currentTimeMillis() / 1000).toInt(),
            channelUsername = repliesChannel,
            authorUsername = me.username,
            authorName = me.displayName,
            authorPhoto = me.photo,
            targetKey = targetKey,
            link = "",
            post = Post(
                chatId = 0L, messageId = -System.currentTimeMillis(), date = (System.currentTimeMillis() / 1000).toInt(),
                sourceUsername = me.username, sourceTitle = me.displayName, sourcePhoto = me.photo,
                text = if (body.isEmpty()) null else ca.lucianlabs.tgsocial.model.PostText(body),
            ),
            own = true,
            pending = true,
        )
        viewModelScope.launch {
            _commentComposer.update { it.copy(posting = true) }
            commentRepo.addPending(optimistic)
            _sheet.value = null
            // The selection is spent the moment the reply is sent: §2.12's target is "whatever you tapped",
            // and leaving it armed would aim the NEXT comment at a comment nobody chose.
            _replyTarget.value = null
            // PROTOCOL §6.2 — the first line is `re: ` + the target's own link, whether that target is the
            // post or the comment the reader tapped.
            val text = CommentFormat.serialise(target.link, body)
            runCatching {
                // The send is a Pending row while it runs (PRODUCT §2.10).
                app.activity.track("Posting your comment") {
                    val chat = tg.call { searchPublicChat(username = repliesChannel) }
                    if (c.photo != null) posting.postPhoto(chat.id, c.photo, text)
                    else myNodeRepo.sendAndAwait(chat.id, text)
                }
            }.onSuccess {
                _commentComposer.value = CommentComposerUi()
                delay(600)
                runCatching { commentRepo.rescan(repliesChannel, _myNode.value?.username, myCard) }
                // The send succeeded: the optimistic entry settles even when that rescan failed — the real
                // comment is in the channel and the next scan indexes it.
                commentRepo.removePending(optimistic)
            }.onFailure { e ->
                commentRepo.removePending(optimistic)
                _commentComposer.update { it.copy(posting = false) }
                if (!isCancelled(e)) fail(e)
            }
        }
    }

    /** PRODUCT §2.12 — `Delete this comment?` confirmed: the message in my channel goes. */
    fun deleteComment(comment: Comment) {
        if (demoRefusesWrite()) return
        _sheet.value = null
        viewModelScope.launch {
            runCatching { commentRepo.delete(comment) }
                .onFailure { e -> if (!isCancelled(e)) fail(e) }
        }
    }

    // ------------------------------------------------------------------ safety (PRODUCT §2.15–§2.21)

    /**
     * PROTOCOL §7.1 — the record, off disk, as written. This takes no account id and runs before anything
     * else in `bootstrap`: whose lists they are is a question only Telegram can answer, and the filter is not
     * allowed to wait for that answer (PRODUCT §2.18). Applying a record that turns out to belong to a
     * previous account for a few hundred milliseconds over-filters; not applying one under-filters, and only
     * one of those is a screen the reader asked never to see again.
     */
    private suspend fun restoreSafety() {
        _safety.value = store.moderation()
    }

    /**
     * PROTOCOL §7.1 — key the record to this account, once `getMe` has named it. A failed `getMe` (offline at
     * boot) passes null and the record is kept as written: the lists are only ever replaced when Telegram has
     * actually named a *different* user.
     */
    private suspend fun adoptSafetyAccount(accountId: Long?) {
        val stored = _safety.value
        val mine = stored.forAccount(accountId ?: stored.userId)
        _safety.value = mine
        if (mine != stored) store.saveModeration(mine)
    }

    /** One write path, so nothing can change a list in memory and forget to persist it. */
    private fun updateSafety(transform: (SafetyLists) -> SafetyLists) {
        // PROTOCOL §7.1 — a demo's record is held in memory by the session and MUST NOT be written to any of
        // the three homes. This is the only place a list changes, so it is the only place that has to know.
        _demo.value?.let { session ->
            _safety.value = session.updateSafety(transform)
            return
        }
        val next = transform(_safety.value)
        if (next == _safety.value) return
        _safety.value = next
        viewModelScope.launch { store.saveModeration(next) }
    }

    /** PRODUCT §2.16 — confirmed. The blocked node is not told: there is nowhere for a notification to come from. */
    fun block(username: String) {
        _sheet.value = null
        updateSafety { it.block(username) }
        toast.show("Blocked @$username.", HPToastTone.GOOD)
    }

    /** One tap, no confirm — from the blocked node's own profile or from Settings. */
    fun unblock(username: String) {
        updateSafety { it.unblock(username) }
        toast.show("Unblocked @$username.", HPToastTone.GOOD)
    }

    /** PRODUCT §2.17 — no confirm: it is one tap to undo in the same two places. [title] is the channel's. */
    fun muteFeed(username: String, title: String) {
        updateSafety { it.mute(username) }
        toast.show("Muted $title.", HPToastTone.GOOD)
    }

    fun unmuteFeed(username: String, title: String) {
        updateSafety { it.unmute(username) }
        toast.show("Unmuted $title.", HPToastTone.GOOD)
    }

    fun unhide(key: String) {
        updateSafety { it.unhide(key) }
        toast.show("Unhidden. It's back in your feed.", HPToastTone.GOOD)
    }

    /** PRODUCT §2.15 — `Report Post` / `Report Comment` replaces the sheet with the report confirm. */
    fun openReport(subject: ReportSubject) {
        _report.value = ReportUi(subject = subject)
        _sheet.value = Sheet.Report
    }

    fun pickReportReason(reason: String) {
        _report.update { it.copy(reason = reason) }
    }

    /** The mail `Send Report` hands to the platform composer, or null before a reason is picked. */
    fun reportMail(): ReportMail? {
        val r = _report.value
        val subject = r.subject ?: return null
        val reason = r.reason ?: return null
        val mail = ReportEmail.compose(subject, reason, APP_VERSION)
        // PRODUCT §2.22.2 — the one deviation from §2.15, and the only thing the demo ever sends: one line at
        // the top of the body. Without it the operator opens their inbox and hunts for a channel that does not
        // exist. Everything §2.15 specifies is still there, unchanged, underneath it.
        return DemoCopy.report(mail, inDemo)
    }

    /**
     * PRODUCT §2.15 — hiding is immediate and **unconditional**. The app cannot know whether a mail was
     * actually sent, and the reader has already said they do not want to see this; so [mailOpened] changes
     * the toast and nothing else.
     */
    fun confirmReport(mailOpened: Boolean) {
        val r = _report.value
        val subject = r.subject ?: return
        val reason = r.reason ?: return
        _sheet.value = null
        _report.value = ReportUi()
        updateSafety { it.hide(subject.key, reason, nowIso()) }
        if (mailOpened) toast.show("Reported. It's hidden here now.", HPToastTone.GOOD)
        else toast.show("No mail app. Write to ${ReportEmail.ADDRESS}.", HPToastTone.BAD)
    }

    /** PROTOCOL §7.1 — `at`, ISO 8601 UTC to the second. */
    private fun nowIso(): String = java.time.Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS).toString()

    // ---- delete my node (PRODUCT §2.21)

    fun setDeleteNodeInput(value: String) {
        _deleteNode.update { it.copy(input = value) }
    }

    /** Case-insensitive, and a missing `@` is not a reason to refuse someone their own username. */
    fun deleteNodeConfirmed(input: String): Boolean =
        _myNode.value?.username?.equals(input.trim().removePrefix("@"), ignoreCase = true) == true

    fun deleteMyNode() {
        val node = _myNode.value ?: return
        if (!deleteNodeConfirmed(_deleteNode.value.input) || _deleteNode.value.running) return
        // PRODUCT §2.22.2 — the demo runs the whole §2.21 flow against the fixtures: the modal naming
        // @tgs_demo_you and @tgs_demo_you_r, the type-to-confirm, the comments channel first. This is the
        // point of the demo being visible — Guideline 5.1.1(v) asks for an in-app way to delete the account,
        // and nobody who cannot make an account can reach it any other way. One deviation from §2.21's
        // outcome, because a demo has no session to survive: the demo ends.
        _demo.value?.let { session ->
            session.deleteNode()
            _sheet.value = null
            _deleteNode.value = DeleteNodeUi()
            leaveDemo(DemoCopy.NODE_GONE)
            return
        }
        if (tg.isOffline) { toast.show("You're offline.", HPToastTone.BAD); return }
        _deleteNode.update { it.copy(running = true, message = null, openUsername = null) }
        viewModelScope.launch {
            val result = try {
                myNodeRepo.deleteNode(node, myCard, commentsAlreadyGone = _deleteNode.value.commentsGone)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                MyNodeRepo.DeleteResult.Failed(node.username, errorCopy(e))
            }
            when (result) {
                is MyNodeRepo.DeleteResult.Deleted -> {
                    _sheet.value = null
                    _deleteNode.value = DeleteNodeUi()
                    discardNodeState()
                    toast.show("Your node is gone.", HPToastTone.GOOD)
                }
                is MyNodeRepo.DeleteResult.NotOwner -> _deleteNode.update {
                    it.copy(
                        running = false,
                        message = "Telegram won't let you delete @${result.username} — only the channel's owner can. Open it in Telegram to see who owns it.",
                        openUsername = result.username,
                    )
                }
                is MyNodeRepo.DeleteResult.Failed -> _deleteNode.update {
                    it.copy(running = false, message = "Couldn't delete @${result.username} — Telegram said: ${result.error}. Nothing was deleted.", openUsername = null)
                }
                is MyNodeRepo.DeleteResult.NodeFailed -> {
                    // PROTOCOL §4.11 step 2 stripped `replies:` on Telegram; the copy held here has to follow.
                    // `Try Again` passes this card straight back in, and the comment composer reads it too —
                    // both would go on pointing at a channel that no longer exists.
                    _me.update { snap -> snap?.card?.let { snap.copy(card = it.copy(replies = null)) } ?: snap }
                    _deleteNode.update {
                        it.copy(running = false, commentsGone = true, message = "Your comments channel is gone. @${result.username} is still there — Telegram said: ${result.error}.", openUsername = null)
                    }
                }
            }
        }
    }

    /**
     * PRODUCT §2.21 — both channels went. Local state is wiped exactly as Sign Out wipes it (the safety lists
     * included: `LocalStore.wipe` keeps them, and they protect the person, not the node), but there is no
     * `logOut` — the session stays authorized and the client is nodeless, so it lands on Setup.
     */
    private suspend fun discardNodeState() {
        feedJob?.cancel()
        candidatesJob?.cancel()
        candidateRefreshJob?.cancel()
        store.wipe()
        nodes.clear()
        commentRepo.clear()
        feedRepo.reset()
        app.media.clear()
        app.strips.clear()
        app.playback.stopAudio()
        app.activity.clear()
        _myNode.value = null
        _me.value = null
        _feed.value = FeedUi()
        _explore.value = ExploreUi()
        _graph.value = GraphUi()
        _profile.value = ProfileUi()
        _channel.value = ChannelUi()
        _setup.value = SetupUi()
        _compose.value = ComposeUi()
        _commentComposer.value = CommentComposerUi()
        _stack.value = listOf(Screen.Home)
        _viewer.value = null
        _tab.value = Tab.FEED
        _setupNeeded.value = true
        prepareSetup()
    }

    // ------------------------------------------------------------------ explore

    fun setQuery(q: String) { _explore.update { it.copy(query = q) } }

    fun submitQuery() {
        val u = Username.normalise(_explore.value.query) ?: run { toast.show("Not a tgsocial node.", HPToastTone.BAD); return }
        _demo.value?.let { session ->
            // §2.4 in the demo: an exact `tgs_demo_*` username opens that profile, anything else says so.
            val found = session.find(u) ?: run { toast.show("Not a tgsocial node.", HPToastTone.BAD); return }
            _explore.update { it.copy(query = "") }
            push(Screen.Profile(found))
            return
        }
        viewModelScope.launch {
            val snap = runCatching { nodes.fetch(u) }.getOrNull()
            if (snap?.card == null) { toast.show(if (snap?.newerVersion == true) "Newer card. Update the app." else "Not a tgsocial node.", HPToastTone.BAD); return@launch }
            _explore.update { it.copy(query = "") }
            push(Screen.Profile(snap.username))
        }
    }

    fun loadExplore() {
        _demo.value?.let { session ->
            _explore.update { it.copy(nearby = session.nearby(), directory = session.directory(), loading = false, loaded = true) }
            return
        }
        viewModelScope.launch {
            _explore.update { it.copy(loading = true) }
            val nearby = runCatching { discovery.nearby(_myNode.value?.username, myCard) }.getOrDefault(emptyList())
            _explore.update { it.copy(nearby = nearby) }
            val exclude = HashSet<String>()
            _myNode.value?.username?.let { exclude += Username.key(it) }
            myCard?.follows?.forEach { exclude += Username.key(it) }
            nearby.forEach { exclude += Username.key(it.username) }
            val directory = runCatching { discovery.directory(exclude) }.getOrDefault(emptyList())
            _explore.update { it.copy(directory = directory, loading = false, loaded = true) }
            nodes.persist()
        }
    }

    // ------------------------------------------------------------------ graph

    fun loadGraph() {
        _demo.value?.let { session ->
            _graph.update { it.copy(direct = session.direct(), plusOne = session.nearby(), loading = false, loaded = true) }
            return
        }
        viewModelScope.launch {
            _graph.update { it.copy(loading = true) }
            val direct = myCard?.follows.orEmpty().mapNotNull { f -> runCatching { nodes.node(f) }.getOrNull()?.let { discovery.entry(it) } }
            val plusOne = runCatching { discovery.nearby(_myNode.value?.username, myCard) }.getOrDefault(emptyList())
            _graph.update { it.copy(direct = direct, plusOne = plusOne, loading = false, loaded = true) }
        }
    }

    /** Which node does a +1 entry hang off (for the radial layout)? The first of my follows that lists it. */
    fun parentOf(plusOne: String): String? {
        val k = Username.key(plusOne)
        val snapshots = cards.value
        return myCard?.follows?.firstOrNull { f -> snapshots[Username.key(f)]?.card?.follows?.any { Username.key(it) == k } == true }
    }

    // ------------------------------------------------------------------ profile / channel

    fun isMe(username: String): Boolean = _myNode.value?.username?.let { Username.same(it, username) } == true
    fun isFollowing(username: String): Boolean = myCard?.follows(username) == true

    private fun loadProfile(username: String) {
        _demo.value?.let { session ->
            val snap = session.snapshot(username)
            _profile.value = ProfileUi(
                username = username,
                snapshot = snap,
                loading = false,
                notANode = snap == null,
                feeds = session.feedsOf(username),
                follows = session.followsOf(username),
            )
            return
        }
        _profile.value = ProfileUi(username = username, snapshot = nodes.cached(username), loading = true)
        viewModelScope.launch {
            val snap = runCatching { nodes.fetch(username) }.getOrNull() ?: nodes.cached(username)
            if (snap == null) { _profile.update { it.copy(loading = false, notANode = true) }; return@launch }
            _profile.update { it.copy(snapshot = snap, notANode = snap.card == null && !snap.newerVersion, newerVersion = snap.newerVersion) }
            val card = snap.card
            if (card != null) {
                val feeds = card.feeds.mapNotNull { nodes.feedSource(it, listOf(snap.username)) }
                _profile.update { it.copy(feeds = feeds) }
                val follows = card.follows.mapNotNull { f ->
                    val s = nodes.cached(f) ?: runCatching { nodes.node(f) }.getOrNull()
                    s?.let { discovery.entry(it) } ?: NodeEntry(username = f, name = "@$f", feedCount = 0)
                }
                _profile.update { it.copy(follows = follows) }
            }
            _profile.update { it.copy(loading = false) }
            nodes.persist()
        }
    }

    private fun loadChannel(username: String) {
        _demo.value?.let { session ->
            val src = session.feedSource(username)
            _channel.value = ChannelUi(
                username = username,
                source = src,
                posts = FeedOrder.sort(session.channelPosts(username)),
                loading = false,
                exhausted = true,
                verified = src?.verifiedFor?.isNotEmpty() == true,
            )
            return
        }
        val cached = nodes.cachedFeedSource(username)
        _channel.value = ChannelUi(username = username, source = cached, loading = true, verified = cached?.verifiedFor?.isNotEmpty() == true)
        viewModelScope.launch {
            // Nodes that list this feed (PROTOCOL §3): whoever listed it before, plus every cached card that names it
            // (mine, the profile this was opened from, my follows). The Verified pill is backlink ∩ listing node.
            val listedBy = (cached?.listedBy.orEmpty() + listingNodes(username)).distinct()
            val src = nodes.feedSource(username, listedBy, refresh = true) ?: run { _channel.update { it.copy(loading = false, exhausted = true) }; return@launch }
            val (posts, cursor) = runCatching { feedRepo.channelPosts(src) }.getOrDefault(emptyList<Post>() to null)
            _channel.update { it.copy(source = src, posts = FeedOrder.sort(posts), cursor = cursor, exhausted = cursor == null, loading = false, verified = src.verifiedFor.isNotEmpty()) }
        }
    }

    /** Usernames of every cached node whose card lists [feed]. */
    private fun listingNodes(feed: String): List<String> =
        nodes.cards.value.values.filter { s -> s.card?.feeds?.any { Username.same(it, feed) } == true }.map { it.username }

    fun loadMoreChannel() {
        if (inDemo) return
        val c = _channel.value
        val src = c.source ?: return
        if (c.loading || c.exhausted) return
        viewModelScope.launch {
            _channel.update { it.copy(loading = true) }
            val (posts, cursor) = runCatching { feedRepo.channelPosts(src, c.cursor ?: 0L) }.getOrDefault(emptyList<Post>() to null)
            // Channel pages append below, order re-asserted — newest first end to end (PRODUCT §2.3).
            _channel.update { it.copy(posts = FeedOrder.append(it.posts, posts), cursor = cursor, exhausted = cursor == null, loading = false) }
        }
    }

    // ------------------------------------------------------------------ card writes (optimistic)

    private fun writeCard(next: Card, onDone: (() -> Unit)? = null) {
        // §2.22.3 — Follow / Unfollow, Edit Card, the feed toggles and the Public listing toggle all land here.
        if (demoRefusesWrite()) return
        val node = _myNode.value ?: run { toast.show("Make your node first.", HPToastTone.BAD); return }
        val previous = _me.value ?: return
        if (previous.newerVersion) { toast.show("Newer card. Update the app.", HPToastTone.BAD); return }
        if (tg.isOffline) { toast.show("You're offline.", HPToastTone.BAD); return }
        if (CardFormat.isFull(next)) { toast.show("Card is full.", HPToastTone.BAD); return }
        _me.value = previous.copy(card = next)
        viewModelScope.launch {
            runCatching { myNodeRepo.writeCard(node, next) }
                .onSuccess { updated -> _myNode.value = updated; nodes.persist(); onDone?.invoke() }
                .onFailure { e ->
                    _me.value = previous
                    nodes.put(previous)
                    app.activity.recordError((e as? TdError)?.message ?: e.message.orEmpty())
                    toast.show("Couldn't update your card. ${errorCopy(e)}", HPToastTone.BAD)
                }
        }
    }

    fun follow(username: String) {
        val card = cardOrToast() ?: return
        if (card.follows(username)) return
        writeCard(card.withFollow(username)) { refreshFeed(resetCursors = true); _graph.update { it.copy(loaded = false) } }
    }

    fun unfollow(username: String) {
        val card = myCard ?: return
        writeCard(card.withoutFollow(username)) { refreshFeed(resetCursors = true); _graph.update { it.copy(loaded = false) } }
    }

    fun setPublic(public: Boolean) {
        val card = myCard ?: return
        writeCard(card.copy(public = public))
    }

    fun setEditCard(name: String? = null, bio: String? = null, link: String? = null) {
        _editCard.update { it.copy(name = name ?: it.name, bio = bio ?: it.bio, link = link ?: it.link) }
    }

    fun saveEditCard() {
        val card = myCard ?: return
        val e = _editCard.value
        _sheet.value = null
        writeCard(card.copy(name = e.name.trim().ifEmpty { null }, bio = e.bio.trim().ifEmpty { null }, link = e.link.trim().ifEmpty { null }))
    }

    fun announce() {
        if (demoRefusesWrite()) return
        val node = _myNode.value ?: return
        val card = myCard ?: return
        viewModelScope.launch {
            runCatching { myNodeRepo.announce(node, card) }
                .onSuccess { toast.show("Announced.", HPToastTone.GOOD) }
                .onFailure { fail(it) }
        }
    }

    // ------------------------------------------------------------------ setup

    fun prepareSetup() {
        // §2.22.3 — `Make Channel`, `Create Node` and the feed toggles are all disabled in the demo, and the
        // candidate list behind them is a live TDLib query (`getCreatedPublicChats` plus the admin scan). The
        // screen is still reachable from You → Manage; it simply has nothing to ask.
        if (inDemo) return
        viewModelScope.launch {
            if (_me.value == null && _setup.value.nodeName.isEmpty()) {
                val suggested = runCatching { myNodeRepo.suggestedUsername() }.getOrDefault("tgs_")
                _setup.update { it.copy(nodeName = suggested) }
                checkAvailability()
            }
            loadCandidates()
        }
    }

    fun setNodeName(name: String) {
        if (inDemo) return
        _setup.update { it.copy(nodeName = name.trim(), availability = Availability.UNKNOWN) }
        checkAvailability()
    }

    private fun checkAvailability() {
        availabilityJob?.cancel()
        availabilityJob = viewModelScope.launch {
            delay(450)
            val name = _setup.value.nodeName
            if (Username.normalise(name) != name || name.isEmpty()) { _setup.update { it.copy(availability = Availability.TAKEN, availabilityNote = "Invalid") }; return@launch }
            _setup.update { it.copy(availability = Availability.CHECKING) }
            val chatId = _myNode.value?.chatId ?: 0L
            val r = runCatching { myNodeRepo.checkUsername(name, chatId) }.getOrNull()
            _setup.update {
                when (r) {
                    is MyNodeRepo.Availability.Available -> it.copy(availability = Availability.AVAILABLE, availabilityNote = "")
                    is MyNodeRepo.Availability.Taken -> it.copy(availability = Availability.TAKEN, availabilityNote = r.reason)
                    null -> it.copy(availability = Availability.UNKNOWN)
                }
            }
        }
    }

    fun createNode() {
        if (demoRefusesWrite()) return
        val name = _setup.value.nodeName
        if (Username.normalise(name) != name) { toast.show("That name isn't allowed.", HPToastTone.BAD); return }
        if (tg.isOffline) { toast.show("You're offline.", HPToastTone.BAD); return }
        viewModelScope.launch {
            _setup.update { it.copy(creating = true) }
            val me = runCatching { myNodeRepo.me() }.getOrNull()
            val display = listOfNotNull(me?.firstName, me?.lastName).joinToString(" ").trim().ifEmpty { null }
            runCatching { myNodeRepo.create(name, Card(name = display)) }
                .onSuccess { (node, snap) ->
                    _myNode.value = node
                    _me.value = snap
                    // Stay on Setup: Card 2 (Your feeds) appears once the node exists (PRODUCT §2.2).
                    // `_setupNeeded` is cleared by saveFeeds() or skipSetup(), not here.
                    nodes.persist()
                    loadCandidates()
                }
                .onFailure { fail(it) }
            _setup.update { it.copy(creating = false) }
        }
    }

    fun findExistingNode() {
        if (demoRefusesWrite()) return
        viewModelScope.launch {
            val ok = findMyNode(quiet = false)
            if (!ok) toast.show("No node found.", HPToastTone.BAD) else { nodes.persist(); loadCandidates(); refreshFeed() }
        }
    }

    fun skipSetup() {
        viewModelScope.launch { store.saveSetupSkipped(true) }
        _setupNeeded.value = false
        if (_stack.value.lastOrNull() is Screen.Setup) back()
    }

    /**
     * PRODUCT §2.2 — the candidate list is never trusted stale: every open of the Setup feeds card or Manage
     * feeds re-queries live (getCreatedPublicChats + the admin-channel scan). The cached list stays on screen
     * while the query runs — the pill reads `Syncing` via the activity registry — and the fresh result replaces
     * it. [seedSelection] re-seeds the toggles from my card on open; a background refresh keeps them, so an
     * unsaved selection survives a channel appearing mid-edit.
     */
    private fun loadCandidates(seedSelection: Boolean = true) {
        candidatesJob?.cancel()
        candidatesJob = viewModelScope.launch {
            if (seedSelection) _setup.update { it.copy(selected = myCard?.feeds?.map { f -> Username.key(f) }?.toSet() ?: emptySet()) }
            _setup.update { it.copy(candidatesLoading = true) }
            val list = try {
                app.activity.track("Checking your channels") { myNodeRepo.feedCandidates(_myNode.value?.chatId ?: 0L) }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                // The query failed (offline, timeout): keep the cached list rather than blanking the card.
                _setup.update { it.copy(candidatesLoading = false) }
                return@launch
            }
            val node = _myNode.value?.username
            val verified = list.filter { c -> c.username != null && node != null && ca.lucianlabs.tgsocial.protocol.Backlink.isVerified(c.description, node) }.map { Username.key(it.username!!) }.toSet()
            _setup.update { it.copy(candidates = list, candidatesLoading = false, verified = verified) }
        }
    }

    /** Is a surface that shows the feed-candidate list on screen (Setup pushed, Manage feeds, or first-run Setup on Home)? */
    private fun setupSurfaceVisible(): Boolean {
        val top = _stack.value.lastOrNull()
        return top is Screen.Setup || top is Screen.ManageFeeds || (top is Screen.Home && _setupNeeded.value)
    }

    /**
     * A candidacy-changing TDLib update arrived. While the Setup/Manage surface is visible, re-query live after a
     * ~1 s debounce (bursts collapse into one query), waiting out any query already in flight — its own loadChats
     * echoes back as updates, and re-querying per echo would loop; TDLib only announces each chat once per
     * session, so the one coalesced follow-up query echoes nothing and the chain stops. When the surface is not
     * visible nothing runs: opening it always re-queries anyway, so the cache is never served stale.
     */
    private fun scheduleCandidateRefresh() {
        if (inDemo) return
        if (!bootstrapped || _auth.value.step != AuthStep.READY) return
        if (!setupSurfaceVisible()) return
        candidateRefreshJob?.cancel()
        candidateRefreshJob = viewModelScope.launch {
            delay(1_000)
            candidatesJob?.join()
            if (setupSurfaceVisible()) loadCandidates(seedSelection = false)
        }
    }

    fun toggleFeed(username: String, on: Boolean) {
        if (demoRefusesWrite()) return
        val k = Username.key(username)
        _setup.update {
            val sel = if (on) it.selected + k else it.selected - k
            it.copy(selected = sel, verifyPrompt = if (on && k !in it.verified) username else if (!on && it.verifyPrompt?.let { p -> Username.key(p) } == k) null else it.verifyPrompt)
        }
    }

    fun answerVerify(verify: Boolean) {
        if (demoRefusesWrite()) return
        val prompt = _setup.value.verifyPrompt ?: return
        _setup.update { it.copy(verifyPrompt = null) }
        if (!verify) return
        val node = _myNode.value?.username ?: return
        val cand = _setup.value.candidates.firstOrNull { it.username?.let { u -> Username.same(u, prompt) } == true } ?: return
        viewModelScope.launch {
            runCatching { myNodeRepo.verifyFeed(cand.chatId, cand.description, node) }
                .onSuccess { _setup.update { it.copy(verified = it.verified + Username.key(prompt)) }; toast.show("Verified.", HPToastTone.GOOD) }
                .onFailure { fail(it) }
        }
    }

    fun saveFeeds() {
        if (demoRefusesWrite()) return
        val card = cardOrToast() ?: return
        val s = _setup.value
        val chosen = s.candidates.mapNotNull { c -> c.username?.takeIf { Username.key(it) in s.selected } }
        _setup.update { it.copy(saving = true) }
        writeCard(card.copy(feeds = chosen)) {
            _setup.update { it.copy(saving = false) }
            toast.show("Feeds saved.", HPToastTone.GOOD)
            if (_setupNeeded.value) _setupNeeded.value = false
            if (_stack.value.lastOrNull().let { it is Screen.Setup || it is Screen.ManageFeeds }) back()
            refreshFeed(resetCursors = true)
        }
        viewModelScope.launch { delay(600); _setup.update { it.copy(saving = false) } }
    }

    fun cachedFeedSource(username: String): FeedSource? =
        _demo.value?.feedSource(username) ?: nodes.cachedFeedSource(username)

    suspend fun resolveFeedSources(feeds: List<String>): List<FeedSource> =
        _demo.value?.let { session -> feeds.mapNotNull { session.feedSource(it) } }
            ?: feeds.mapNotNull { nodes.feedSource(it, listOfNotNull(_myNode.value?.username)) }

    // ------------------------------------------------------------------ compose

    /**
     * §2.22.4 — both reads here go through the demo-aware helpers above, not through [nodes] directly.
     * Reaching `NodeRepo` for an uncached feed means `searchPublicChat`, and the demo's `@demo_you_notes` is
     * never in that cache: this was the one read path that would have asked Telegram to resolve an invented
     * username, and the reviewer's Compose sheet would have opened with no feed to post to besides.
     */
    private fun prepareCompose(feedUsername: String?) {
        val wanted = myCard?.feeds.orEmpty()
        val feeds = wanted.mapNotNull { cachedFeedSource(it) }
        val idx = feedUsername?.let { u -> feeds.indexOfFirst { Username.same(it.username, u) } }?.takeIf { it >= 0 } ?: 0
        _compose.value = ComposeUi(feeds = feeds, selected = idx)
        if (feeds.size < wanted.size) {
            viewModelScope.launch {
                val all = resolveFeedSources(wanted)
                val i = feedUsername?.let { u -> all.indexOfFirst { Username.same(it.username, u) } }?.takeIf { it >= 0 } ?: 0
                _compose.update { it.copy(feeds = all, selected = i) }
            }
        }
    }

    fun composeSelect(i: Int) { _compose.update { it.copy(selected = i) } }
    fun composeText(t: String) { _compose.update { it.copy(text = t) } }
    fun composePhoto(uri: Uri?) { _compose.update { it.copy(photo = uri) } }

    fun post() {
        if (demoRefusesWrite()) return
        val c = _compose.value
        val feed: FeedSource = c.feeds.getOrNull(c.selected) ?: run { toast.show("Pick a feed first.", HPToastTone.BAD); return }
        if (c.text.isBlank() && c.photo == null) return
        if (tg.isOffline) { toast.show("You're offline.", HPToastTone.BAD); return }
        viewModelScope.launch {
            _compose.update { it.copy(posting = true) }
            runCatching {
                // The send is a Pending row while it runs (PRODUCT §2.10).
                app.activity.track("Posting to @${feed.username}") {
                    if (c.photo != null) posting.postPhoto(feed.chatId, c.photo, c.text.trim()) else posting.postText(feed.chatId, c.text.trim())
                }
            }.onSuccess {
                _sheet.value = null
                _compose.value = ComposeUi()
                toast.show("Posted.", HPToastTone.GOOD)
                delay(1200)
                refreshFeed(resetCursors = true)
            }.onFailure {
                _compose.update { s -> s.copy(posting = false) }
                fail(it)
            }
        }
    }

    // ------------------------------------------------------------------ sign out

    fun signOut() {
        // §2.22.3 — `Sign Out` is not in the demo at all; Settings carries `( Leave Demo )` in its place.
        if (inDemo) { leaveDemo(); return }
        _sheet.value = null
        _auth.update { it.copy(busy = true) }
        viewModelScope.launch {
            wipeLocal()
            runCatching { tg.client.logOut() }
        }
    }

    private suspend fun wipeLocal() {
        bootstrapped = false
        feedJob?.cancel()
        candidatesJob?.cancel()
        candidateRefreshJob?.cancel()
        store.wipe()
        nodes.clear()
        commentRepo.clear()
        app.media.clear()
        app.strips.clear()
        app.playback.release()
        app.activity.clear()
        _phone.value = ""
        _myNode.value = null
        _me.value = null
        _setupNeeded.value = false
        _feed.value = FeedUi()
        _explore.value = ExploreUi()
        _graph.value = GraphUi()
        _profile.value = ProfileUi()
        _channel.value = ChannelUi()
        _setup.value = SetupUi()
        _compose.value = ComposeUi()
        _commentComposer.value = CommentComposerUi()
        // PROTOCOL §7.1 — `_safety` is deliberately NOT reset here. The record outlives sign-out and is keyed
        // to the account that wrote it, so the next sign-in either gets its own lists back or starts empty.
        _report.value = ReportUi()
        _deleteNode.value = DeleteNodeUi()
        _stack.value = listOf(Screen.Home)
        _sheet.value = null
        _viewer.value = null
        _tab.value = Tab.FEED
    }
}
