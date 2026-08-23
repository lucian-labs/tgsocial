package ca.lucianlabs.tgsocial.ui

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import ca.lucianlabs.housepour.HPToastState
import ca.lucianlabs.housepour.HPToastTone
import ca.lucianlabs.tgsocial.TgApp
import ca.lucianlabs.tgsocial.model.FeedSource
import ca.lucianlabs.tgsocial.model.MyNode
import ca.lucianlabs.tgsocial.model.NodeEntry
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.model.SyncStatus
import ca.lucianlabs.tgsocial.protocol.Card
import ca.lucianlabs.tgsocial.protocol.CardFormat
import ca.lucianlabs.tgsocial.protocol.Username
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
import dev.g000sha256.tdl.dto.ConnectionStateReady
import dev.g000sha256.tdl.dto.ConnectionStateWaitingForNetwork
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as TgApp
    private val tg get() = app.tg
    private val store get() = app.store
    private val nodes get() = app.nodes
    private val myNodeRepo get() = app.myNode
    private val feedRepo get() = app.feed
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

    private val _syncing = MutableStateFlow(0)
    val status: StateFlow<SyncStatus> = combine(tg.connection, _syncing, _auth) { conn, busy, a ->
        when {
            a.step != AuthStep.READY -> SyncStatus.SIGNED_OUT
            conn is ConnectionStateWaitingForNetwork -> SyncStatus.OFFLINE
            busy > 0 || (conn != null && conn !is ConnectionStateReady) -> SyncStatus.SYNCING
            else -> SyncStatus.SYNCED
        }
    }.stateIn(viewModelScope, SharingStarted.Eagerly, SyncStatus.SIGNED_OUT)

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

    val cards get() = nodes.cards

    private var bootstrapped = false
    private var feedJob: Job? = null
    private var availabilityJob: Job? = null

    init {
        viewModelScope.launch { tg.authState.collect { onAuth(it) } }
        viewModelScope.launch { tg.floodWaits.collect { toast.show("Telegram asked us to wait ${it.seconds} s.", HPToastTone.BAD) } }
        viewModelScope.launch {
            tg.newMessages.collect { m ->
                if (!bootstrapped || m.isOutgoing && m.sendingState != null) return@collect
                val post = runCatching { feedRepo.liveToPost(m) }.getOrNull() ?: return@collect
                _feed.update { f -> if (f.posts.any { it.key == post.key }) f else f.copy(posts = (listOf(post) + f.posts).sortedByDescending { it.date }) }
            }
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

    // ------------------------------------------------------------------ bootstrap

    private fun bootstrap() {
        if (bootstrapped) return
        bootstrapped = true
        viewModelScope.launch {
            sync {
                nodes.restore()
                _tab.value = Tab.entries[store.lastTab().coerceIn(0, Tab.entries.lastIndex)]
                // Cold start: the last cached feed first, never a blank screen behind a spinner.
                val cached = feedRepo.cachedFeed()
                if (cached.isNotEmpty()) _feed.update { it.copy(posts = cached, ready = true) }
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
            }
            refreshFeed(resetCursors = true)
        }
    }

    private suspend fun findMyNode(quiet: Boolean): Boolean {
        val found = runCatching { myNodeRepo.find() }.onFailure { if (!quiet) toast.show(errorCopy(it), HPToastTone.BAD) }.getOrNull()
        if (found != null) {
            _myNode.value = found.first
            _me.value = found.second
            // Setup stays up (when it is up) so Card 2 can show the feeds of the node just found; saveFeeds()/skipSetup() exit.
            if (found.second.newerVersion && !quiet) toast.show("Newer card. Update the app.", HPToastTone.BAD)
            return true
        }
        return false
    }

    private suspend inline fun <T> sync(block: () -> T): T {
        _syncing.update { it + 1 }
        try { return block() } finally { _syncing.update { (it - 1).coerceAtLeast(0) } }
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
            else -> Unit
        }
    }

    /** Returns false when there was nothing to pop (let the system handle back). */
    fun back(): Boolean {
        if (_sheet.value != null) { closeSheet(); return true }
        if (_stack.value.size > 1) {
            _stack.update { it.dropLast(1) }
            // The pushed-screen state is single-slot; reload whatever is now on top.
            when (val top = _stack.value.last()) {
                is Screen.Profile -> loadProfile(top.username)
                is Screen.FeedChannel -> loadChannel(top.username)
                else -> Unit
            }
            return true
        }
        return false
    }

    fun openSheet(s: Sheet) {
        when (s) {
            is Sheet.Compose -> prepareCompose(s.feedUsername)
            Sheet.EditCard -> _editCard.value = EditCardUi(name = myCard?.name.orEmpty(), bio = myCard?.bio.orEmpty(), link = myCard?.link.orEmpty())
            Sheet.SignOut -> Unit
        }
        _sheet.value = s
    }

    fun closeSheet() {
        if (_sheet.value is Sheet.Compose && _compose.value.posting) return
        _sheet.value = null
    }

    // ------------------------------------------------------------------ feed

    fun refreshFeed(resetCursors: Boolean = true) {
        feedJob?.cancel()
        feedJob = viewModelScope.launch {
            _feed.update { it.copy(refreshing = true, loading = true) }
            sync {
                runCatching {
                    // Refresh my card and the cards of my follows so new feeds show up. Offline: reads serve cache.
                    if (!tg.isOffline) _myNode.value?.let { n -> runCatching { nodes.fetch(n.username) }.getOrNull()?.let { if (it.card != null) _me.value = it } }
                    val sources = feedRepo.resolveSources(_myNode.value?.username, myCard, fresh = resetCursors)
                    if (resetCursors) feedRepo.reset()
                    val posts = feedRepo.loadMore(20)
                    _feed.update { it.copy(posts = posts, exhausted = feedRepo.exhausted, sourceCount = sources.size, ready = true) }
                    if (posts.isNotEmpty()) feedRepo.cacheFeed(posts)
                    nodes.persist()
                }.onFailure { e ->
                    if (!isCancelled(e)) {
                        _feed.update { it.copy(ready = true) }
                        if (!isQuietOffline(e)) toast.show(errorCopy(e), HPToastTone.BAD)
                    }
                }
            }
            _feed.update { it.copy(refreshing = false, loading = false) }
        }
    }

    fun loadMoreFeed() {
        val f = _feed.value
        if (f.loading || f.exhausted || !f.ready) return
        feedJob = viewModelScope.launch {
            _feed.update { it.copy(loading = true) }
            runCatching { feedRepo.loadMore(20) }
                .onSuccess { more -> _feed.update { it.copy(posts = it.posts + more.filter { p -> it.posts.none { q -> q.key == p.key } }, exhausted = feedRepo.exhausted) } }
                .onFailure { e -> if (!isCancelled(e) && !isQuietOffline(e)) toast.show(errorCopy(e), HPToastTone.BAD) }
            _feed.update { it.copy(loading = false) }
        }
    }

    // ------------------------------------------------------------------ explore

    fun setQuery(q: String) { _explore.update { it.copy(query = q) } }

    fun submitQuery() {
        val u = Username.normalise(_explore.value.query) ?: run { toast.show("Not a tgsocial node.", HPToastTone.BAD); return }
        viewModelScope.launch {
            val snap = runCatching { nodes.fetch(u) }.getOrNull()
            if (snap?.card == null) { toast.show(if (snap?.newerVersion == true) "Newer card. Update the app." else "Not a tgsocial node.", HPToastTone.BAD); return@launch }
            _explore.update { it.copy(query = "") }
            push(Screen.Profile(snap.username))
        }
    }

    fun loadExplore() {
        viewModelScope.launch {
            _explore.update { it.copy(loading = true) }
            sync {
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
    }

    // ------------------------------------------------------------------ graph

    fun loadGraph() {
        viewModelScope.launch {
            _graph.update { it.copy(loading = true) }
            sync {
                val direct = myCard?.follows.orEmpty().mapNotNull { f -> runCatching { nodes.node(f) }.getOrNull()?.let { discovery.entry(it) } }
                val plusOne = runCatching { discovery.nearby(_myNode.value?.username, myCard) }.getOrDefault(emptyList())
                _graph.update { it.copy(direct = direct, plusOne = plusOne, loading = false, loaded = true) }
            }
        }
    }

    /** Which node does a +1 entry hang off (for the radial layout)? The first of my follows that lists it. */
    fun parentOf(plusOne: String): String? {
        val k = Username.key(plusOne)
        return myCard?.follows?.firstOrNull { f -> nodes.cached(f)?.card?.follows?.any { Username.key(it) == k } == true }
    }

    // ------------------------------------------------------------------ profile / channel

    fun isMe(username: String): Boolean = _myNode.value?.username?.let { Username.same(it, username) } == true
    fun isFollowing(username: String): Boolean = myCard?.follows(username) == true

    private fun loadProfile(username: String) {
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
        val cached = nodes.cachedFeedSource(username)
        _channel.value = ChannelUi(username = username, source = cached, loading = true, verified = cached?.verifiedFor?.isNotEmpty() == true)
        viewModelScope.launch {
            // Nodes that list this feed (PROTOCOL §3): whoever listed it before, plus every cached card that names it
            // (mine, the profile this was opened from, my follows). The Verified pill is backlink ∩ listing node.
            val listedBy = (cached?.listedBy.orEmpty() + listingNodes(username)).distinct()
            val src = nodes.feedSource(username, listedBy, refresh = true) ?: run { _channel.update { it.copy(loading = false, exhausted = true) }; return@launch }
            val (posts, cursor) = runCatching { feedRepo.channelPosts(src) }.getOrDefault(emptyList<Post>() to null)
            _channel.update { it.copy(source = src, posts = posts, cursor = cursor, exhausted = cursor == null, loading = false, verified = src.verifiedFor.isNotEmpty()) }
        }
    }

    /** Usernames of every cached node whose card lists [feed]. */
    private fun listingNodes(feed: String): List<String> =
        nodes.cards.value.values.filter { s -> s.card?.feeds?.any { Username.same(it, feed) } == true }.map { it.username }

    fun loadMoreChannel() {
        val c = _channel.value
        val src = c.source ?: return
        if (c.loading || c.exhausted) return
        viewModelScope.launch {
            _channel.update { it.copy(loading = true) }
            val (posts, cursor) = runCatching { feedRepo.channelPosts(src, c.cursor ?: 0L) }.getOrDefault(emptyList<Post>() to null)
            _channel.update { it.copy(posts = it.posts + posts.filter { p -> it.posts.none { q -> q.key == p.key } }, cursor = cursor, exhausted = cursor == null, loading = false) }
        }
    }

    // ------------------------------------------------------------------ card writes (optimistic)

    private fun writeCard(next: Card, onDone: (() -> Unit)? = null) {
        val node = _myNode.value ?: run { toast.show("Make your node first.", HPToastTone.BAD); return }
        val previous = _me.value ?: return
        if (previous.newerVersion) { toast.show("Newer card. Update the app.", HPToastTone.BAD); return }
        if (tg.isOffline) { toast.show("You're offline.", HPToastTone.BAD); return }
        if (CardFormat.isFull(next)) { toast.show("Card is full.", HPToastTone.BAD); return }
        _me.value = previous.copy(card = next)
        viewModelScope.launch {
            sync {
                runCatching { myNodeRepo.writeCard(node, next) }
                    .onSuccess { updated -> _myNode.value = updated; nodes.persist(); onDone?.invoke() }
                    .onFailure { e ->
                        _me.value = previous
                        nodes.put(previous)
                        toast.show("Couldn't update your card. ${errorCopy(e)}", HPToastTone.BAD)
                    }
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
        val node = _myNode.value ?: return
        val card = myCard ?: return
        viewModelScope.launch {
            runCatching { myNodeRepo.announce(node, card) }
                .onSuccess { toast.show("Announced.", HPToastTone.GOOD) }
                .onFailure { toast.show(errorCopy(it), HPToastTone.BAD) }
        }
    }

    // ------------------------------------------------------------------ setup

    fun prepareSetup() {
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
        val name = _setup.value.nodeName
        if (Username.normalise(name) != name) { toast.show("That name isn't allowed.", HPToastTone.BAD); return }
        if (tg.isOffline) { toast.show("You're offline.", HPToastTone.BAD); return }
        viewModelScope.launch {
            _setup.update { it.copy(creating = true) }
            sync {
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
                    .onFailure { toast.show(errorCopy(it), HPToastTone.BAD) }
            }
            _setup.update { it.copy(creating = false) }
        }
    }

    fun findExistingNode() {
        viewModelScope.launch {
            sync {
                val ok = findMyNode(quiet = false)
                if (!ok) toast.show("No node found.", HPToastTone.BAD) else { nodes.persist(); loadCandidates(); refreshFeed() }
            }
        }
    }

    fun skipSetup() {
        viewModelScope.launch { store.saveSetupSkipped(true) }
        _setupNeeded.value = false
        if (_stack.value.lastOrNull() is Screen.Setup) back()
    }

    private fun loadCandidates() {
        viewModelScope.launch {
            _setup.update { it.copy(candidatesLoading = true) }
            val list = runCatching { myNodeRepo.feedCandidates(_myNode.value?.chatId ?: 0L) }.getOrDefault(emptyList())
            val mine = myCard?.feeds?.map { Username.key(it) }?.toSet() ?: emptySet()
            val node = _myNode.value?.username
            val verified = list.filter { c -> c.username != null && node != null && ca.lucianlabs.tgsocial.protocol.Backlink.isVerified(c.description, node) }.map { Username.key(it.username!!) }.toSet()
            _setup.update { it.copy(candidates = list, candidatesLoading = false, selected = mine, verified = verified) }
        }
    }

    fun toggleFeed(username: String, on: Boolean) {
        val k = Username.key(username)
        _setup.update {
            val sel = if (on) it.selected + k else it.selected - k
            it.copy(selected = sel, verifyPrompt = if (on && k !in it.verified) username else if (!on && it.verifyPrompt?.let { p -> Username.key(p) } == k) null else it.verifyPrompt)
        }
    }

    fun answerVerify(verify: Boolean) {
        val prompt = _setup.value.verifyPrompt ?: return
        _setup.update { it.copy(verifyPrompt = null) }
        if (!verify) return
        val node = _myNode.value?.username ?: return
        val cand = _setup.value.candidates.firstOrNull { it.username?.let { u -> Username.same(u, prompt) } == true } ?: return
        viewModelScope.launch {
            runCatching { myNodeRepo.verifyFeed(cand.chatId, cand.description, node) }
                .onSuccess { _setup.update { it.copy(verified = it.verified + Username.key(prompt)) }; toast.show("Verified.", HPToastTone.GOOD) }
                .onFailure { toast.show(errorCopy(it), HPToastTone.BAD) }
        }
    }

    fun saveFeeds() {
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

    fun cachedFeedSource(username: String): FeedSource? = nodes.cachedFeedSource(username)

    suspend fun resolveFeedSources(feeds: List<String>): List<FeedSource> =
        feeds.mapNotNull { nodes.feedSource(it, listOfNotNull(_myNode.value?.username)) }

    // ------------------------------------------------------------------ compose

    private fun prepareCompose(feedUsername: String?) {
        val feeds = myCard?.feeds.orEmpty().mapNotNull { nodes.cachedFeedSource(it) }
        val idx = feedUsername?.let { u -> feeds.indexOfFirst { Username.same(it.username, u) } }?.takeIf { it >= 0 } ?: 0
        _compose.value = ComposeUi(feeds = feeds, selected = idx)
        if (feeds.size < myCard?.feeds.orEmpty().size) {
            viewModelScope.launch {
                val all = myCard?.feeds.orEmpty().mapNotNull { nodes.feedSource(it, listOfNotNull(_myNode.value?.username)) }
                val i = feedUsername?.let { u -> all.indexOfFirst { Username.same(it.username, u) } }?.takeIf { it >= 0 } ?: 0
                _compose.update { it.copy(feeds = all, selected = i) }
            }
        }
    }

    fun composeSelect(i: Int) { _compose.update { it.copy(selected = i) } }
    fun composeText(t: String) { _compose.update { it.copy(text = t) } }
    fun composePhoto(uri: Uri?) { _compose.update { it.copy(photo = uri) } }

    fun post() {
        val c = _compose.value
        val feed: FeedSource = c.feeds.getOrNull(c.selected) ?: run { toast.show("Pick a feed first.", HPToastTone.BAD); return }
        if (c.text.isBlank() && c.photo == null) return
        if (tg.isOffline) { toast.show("You're offline.", HPToastTone.BAD); return }
        viewModelScope.launch {
            _compose.update { it.copy(posting = true) }
            runCatching {
                if (c.photo != null) posting.postPhoto(feed.chatId, c.photo, c.text.trim()) else posting.postText(feed.chatId, c.text.trim())
            }.onSuccess {
                _sheet.value = null
                _compose.value = ComposeUi()
                toast.show("Posted.", HPToastTone.GOOD)
                delay(1200)
                refreshFeed(resetCursors = true)
            }.onFailure {
                _compose.update { s -> s.copy(posting = false) }
                toast.show(errorCopy(it), HPToastTone.BAD)
            }
        }
    }

    // ------------------------------------------------------------------ sign out

    fun signOut() {
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
        store.wipe()
        nodes.clear()
        app.media.clear()
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
        _stack.value = listOf(Screen.Home)
        _sheet.value = null
        _tab.value = Tab.FEED
    }
}
