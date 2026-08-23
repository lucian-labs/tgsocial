package ca.lucianlabs.tgsocial.td

import android.content.Context
import android.os.Build
import ca.lucianlabs.tgsocial.BuildConfig
import dev.g000sha256.tdl.TdlClient
import dev.g000sha256.tdl.TdlResult
import dev.g000sha256.tdl.dto.AuthorizationState
import dev.g000sha256.tdl.dto.AuthorizationStateClosed
import dev.g000sha256.tdl.dto.AuthorizationStateWaitTdlibParameters
import dev.g000sha256.tdl.dto.ChatListMain
import dev.g000sha256.tdl.dto.ChatMemberStatusAdministrator
import dev.g000sha256.tdl.dto.ChatTypeSupergroup
import dev.g000sha256.tdl.dto.ConnectionState
import dev.g000sha256.tdl.dto.ConnectionStateReady
import dev.g000sha256.tdl.dto.ConnectionStateWaitingForNetwork
import dev.g000sha256.tdl.dto.File
import dev.g000sha256.tdl.dto.Message
import dev.g000sha256.tdl.dto.UpdateFile
import dev.g000sha256.tdl.dto.UpdateMessageSendFailed
import dev.g000sha256.tdl.dto.UpdateMessageSendSucceeded
import dev.g000sha256.tdl.dto.UpdateNewMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File as JavaFile

/** A TDLib failure, with FLOOD_WAIT seconds parsed when Telegram sent them. */
class TdError(val code: Int, override val message: String) : Exception(message) {
    val floodWaitSeconds: Int? = parseFloodWait(message)
    val isOffline: Boolean get() = code == -1 || code == 500 && message.contains("network", ignoreCase = true)

    companion object {
        private val FLOOD = Regex("(?:FLOOD_WAIT_|retry after )(\\d+)", RegexOption.IGNORE_CASE)
        fun parseFloodWait(message: String): Int? = FLOOD.find(message)?.groupValues?.get(1)?.toIntOrNull()
    }
}

/** Unwrap a TdlResult, throwing [TdError] on failure. */
fun <T> TdlResult<T>.orThrow(): T = when (this) {
    is TdlResult.Success -> result
    is TdlResult.Failure -> throw TdError(code, message)
}

fun <T> TdlResult<T>.orNull(): T? = (this as? TdlResult.Success)?.result

/** Sent to the UI when Telegram asks us to back off (PRODUCT §4). */
data class FloodWait(val seconds: Int)

/**
 * Application-scoped TDLib wrapper: one client per process lifetime (recreated after logOut → Closed), update
 * collectors attached BEFORE the first request, and a few helpers. Everything else talks to [client] directly.
 */
class TelegramClient(private val context: Context) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @Volatile
    var client: TdlClient = TdlClient.create()
        private set

    private var collectors: Job? = null

    private val _authState = MutableStateFlow<AuthorizationState?>(null)
    val authState: StateFlow<AuthorizationState?> = _authState.asStateFlow()

    private val _connection = MutableStateFlow<ConnectionState?>(null)
    val connection: StateFlow<ConnectionState?> = _connection.asStateFlow()

    private val _files = MutableSharedFlow<File>(extraBufferCapacity = 256)
    val files: SharedFlow<File> = _files.asSharedFlow()

    private val _newMessages = MutableSharedFlow<Message>(extraBufferCapacity = 256)
    val newMessages: SharedFlow<Message> = _newMessages.asSharedFlow()

    private val _sendSucceeded = MutableSharedFlow<UpdateMessageSendSucceeded>(extraBufferCapacity = 64)
    val sendSucceeded: SharedFlow<UpdateMessageSendSucceeded> = _sendSucceeded.asSharedFlow()

    private val _sendFailed = MutableSharedFlow<UpdateMessageSendFailed>(extraBufferCapacity = 64)
    val sendFailed: SharedFlow<UpdateMessageSendFailed> = _sendFailed.asSharedFlow()

    private val _floodWaits = MutableSharedFlow<FloodWait>(extraBufferCapacity = 16)
    val floodWaits: SharedFlow<FloodWait> = _floodWaits.asSharedFlow()

    /**
     * Fires on TDLib updates that can change feed candidacy (PRODUCT §2.2 — "Your feeds"): `updateSupergroup`
     * when a known supergroup's usernames or admin rights actually change (a channel made public, posting rights
     * granted), `updateNewChat` for a channel, and `updateChatPosition` when a channel joins or leaves the main
     * chat list. First sightings during TDLib's own sync are not changes and do not fire (except `updateNewChat`,
     * where a first sighting IS the signal); ordinary reorders from message traffic never fire.
     */
    val candidateChanges: SharedFlow<Unit> get() = _candidateChanges.asSharedFlow()
    private val _candidateChanges = MutableSharedFlow<Unit>(extraBufferCapacity = 64)

    // Collector-local memory for candidateChanges (reset per attach): channel chat ids seen via updateNewChat,
    // main-list membership per channel, and a usernames+rights fingerprint per supergroup.
    private val channelChatIds: MutableSet<Long> = java.util.concurrent.ConcurrentHashMap.newKeySet()
    private val mainListChannelIds: MutableSet<Long> = java.util.concurrent.ConcurrentHashMap.newKeySet()
    private val supergroupFingerprints = java.util.concurrent.ConcurrentHashMap<Long, Int>()

    /** Hooks run after logOut completes (local state wipe), before the new client starts. */
    val onClosed = mutableListOf<() -> Unit>()

    /** Set when the client was closed (after logOut); the next [start] creates a fresh engine client id. */
    private val _closed = MutableStateFlow(false)
    val closed: StateFlow<Boolean> = _closed.asStateFlow()

    val isOnline: Boolean get() = _connection.value.let { it == null || it is ConnectionStateReady || it !is ConnectionStateWaitingForNetwork }
    val isOffline: Boolean get() = _connection.value is ConnectionStateWaitingForNetwork

    val tdlibVersion: String get() = TdlClient.TDL_VERSION

    fun start() {
        attach()
        // The first request starts the TDLib client; the answer is the current state even if the update was missed.
        scope.launch {
            val state = client.getAuthorizationState().orNull() ?: return@launch
            if (_authState.value == null) onAuthState(state)
        }
    }

    private fun attach() {
        collectors?.cancel()
        channelChatIds.clear()
        mainListChannelIds.clear()
        supergroupFingerprints.clear()
        val c = client
        collectors = scope.launch {
            launch { c.authorizationStateUpdates.collect { onAuthState(it.authorizationState) } }
            launch { c.connectionStateUpdates.collect { _connection.value = it.state } }
            launch { c.fileUpdates.collect { u: UpdateFile -> _files.emit(u.file) } }
            launch { c.newMessageUpdates.collect { u: UpdateNewMessage -> _newMessages.emit(u.message) } }
            launch { c.messageSendSucceededUpdates.collect { _sendSucceeded.emit(it) } }
            launch { c.messageSendFailedUpdates.collect { _sendFailed.emit(it) } }
            launch {
                c.newChatUpdates.collect { u ->
                    if ((u.chat.type as? ChatTypeSupergroup)?.isChannel != true) return@collect
                    channelChatIds.add(u.chat.id)
                    _candidateChanges.emit(Unit)
                }
            }
            launch {
                c.chatPositionUpdates.collect { u ->
                    if (u.position.list !is ChatListMain || u.chatId !in channelChatIds) return@collect
                    val joined = u.position.order != 0L && mainListChannelIds.add(u.chatId)
                    val left = u.position.order == 0L && mainListChannelIds.remove(u.chatId)
                    if (joined || left) _candidateChanges.emit(Unit)
                }
            }
            launch {
                c.supergroupUpdates.collect { u ->
                    val sg = u.supergroup
                    val canPost = (sg.status as? ChatMemberStatusAdministrator)?.rights?.canPostMessages
                    val fingerprint = listOf(
                        sg.usernames?.activeUsernames?.joinToString(",").orEmpty(),
                        sg.status::class.java.simpleName,
                        canPost?.toString().orEmpty(),
                    ).joinToString("|").hashCode()
                    val previous = supergroupFingerprints.put(sg.id, fingerprint)
                    if (previous != null && previous != fingerprint) _candidateChanges.emit(Unit)
                }
            }
        }
    }

    private suspend fun onAuthState(state: AuthorizationState) {
        _authState.value = state
        when (state) {
            is AuthorizationStateWaitTdlibParameters -> setParameters()
            is AuthorizationStateClosed -> {
                _closed.value = true
                wipeLocalFiles()
                onClosed.forEach { it() }
                // Fresh engine client for the next sign-in; the old flows complete on Closed.
                client = TdlClient.create()
                _authState.value = null
                _closed.value = false
                start()
            }
            else -> Unit
        }
    }

    private suspend fun setParameters() {
        val base = JavaFile(context.filesDir, "tdl")
        client.setTdlibParameters(
            useTestDc = false,
            databaseDirectory = JavaFile(base, "database").absolutePath,
            filesDirectory = JavaFile(base, "files").absolutePath,
            databaseEncryptionKey = byteArrayOf(),
            useFileDatabase = true,
            useChatInfoDatabase = true,
            useMessageDatabase = true,
            useSecretChats = false,
            apiId = BuildConfig.TG_API_ID,
            apiHash = BuildConfig.TG_API_HASH,
            systemLanguageCode = context.resources.configuration.locales[0].language.ifEmpty { "en" },
            deviceModel = Build.MODEL.ifEmpty { "Android" },
            systemVersion = "Android ${Build.VERSION.RELEASE}",
            applicationVersion = BuildConfig.VERSION_NAME,
        )
    }

    /**
     * Run a TDLib request with FLOOD_WAIT handling (PRODUCT §4): on 429 surface the seconds to the UI, back off that
     * long, retry once. The request timeout wraps each attempt only — never the back-off — so a 40–300 s wait is
     * honoured instead of being cut off as a timeout. Waits past [MAX_AUTO_WAIT_S] are surfaced as a [TdError]
     * (toast with the seconds) rather than holding a UI job for that long.
     */
    suspend fun <T> call(timeoutMs: Long = 40_000L, block: suspend TdlClient.() -> TdlResult<T>): T {
        val first = withTimeout(timeoutMs) { client.block() }
        if (first is TdlResult.Success) return first.result
        val failure = first as TdlResult.Failure
        val wait = TdError.parseFloodWait(failure.message)
        if (failure.code == 429 && wait != null && wait <= MAX_AUTO_WAIT_S) {
            _floodWaits.emit(FloodWait(wait))
            delay(wait * 1000L)
            return withTimeout(timeoutMs) { client.block() }.orThrow()
        }
        throw TdError(failure.code, failure.message)
    }

    companion object {
        /** Longest FLOOD_WAIT retried automatically; longer waits surface as a toast and the action is left to the user. */
        const val MAX_AUTO_WAIT_S = 300
    }

    /**
     * [call] for best-effort reads: null on failure or timeout instead of a throw. Always bounded — a TDLib request
     * with no timeout can sit for as long as the network is bad, and an unbounded request inside a tracked
     * operation is exactly how the status pill used to stick on `Syncing`.
     */
    suspend fun <T> callOrNull(timeoutMs: Long = 40_000L, block: suspend TdlClient.() -> TdlResult<T>): T? =
        try {
            withTimeoutOrNull(timeoutMs) { client.block() }?.orNull()
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            null
        }

    /** Wipes the TDLib directories after logOut; TDLib itself deletes the database, this removes leftovers. */
    fun wipeLocalFiles() {
        JavaFile(context.filesDir, "tdl").deleteRecursively()
    }
}
