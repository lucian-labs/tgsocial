package ca.lucianlabs.tgsocial

import android.app.Application
import androidx.media3.common.util.UnstableApi
import ca.lucianlabs.tgsocial.repo.ActivityRegistry
import ca.lucianlabs.tgsocial.repo.CommentRepo
import ca.lucianlabs.tgsocial.repo.DiscoveryRepo
import ca.lucianlabs.tgsocial.repo.FeedRepo
import ca.lucianlabs.tgsocial.repo.LocalStore
import ca.lucianlabs.tgsocial.repo.MediaRepo
import ca.lucianlabs.tgsocial.repo.MyNodeRepo
import ca.lucianlabs.tgsocial.repo.NodeRepo
import ca.lucianlabs.tgsocial.repo.PostingRepo
import ca.lucianlabs.tgsocial.td.TelegramClient
import ca.lucianlabs.tgsocial.ui.media.PlaybackHub

/** Process-scoped graph: one TDLib client with its collectors attached in onCreate, and the repositories over it. */
@UnstableApi
class TgApp : Application() {
    lateinit var tg: TelegramClient
        private set
    lateinit var activity: ActivityRegistry
        private set
    lateinit var store: LocalStore
        private set
    lateinit var nodes: NodeRepo
        private set
    lateinit var myNode: MyNodeRepo
        private set
    lateinit var feed: FeedRepo
        private set
    lateinit var comments: CommentRepo
        private set
    lateinit var discovery: DiscoveryRepo
        private set
    lateinit var posting: PostingRepo
        private set
    lateinit var media: MediaRepo
        private set
    lateinit var playback: PlaybackHub
        private set

    override fun onCreate() {
        super.onCreate()
        tg = TelegramClient(this)
        activity = ActivityRegistry(tg.scope)
        store = LocalStore(this)
        nodes = NodeRepo(tg, store, activity)
        myNode = MyNodeRepo(tg, store, nodes, activity)
        feed = FeedRepo(tg, nodes, store, activity)
        comments = CommentRepo(tg, nodes, activity)
        discovery = DiscoveryRepo(tg, nodes)
        posting = PostingRepo(this, tg)
        media = MediaRepo(tg, activity)
        playback = PlaybackHub(this, tg)
        feed.displayWidthPx = resources.displayMetrics.widthPixels
        comments.displayWidthPx = resources.displayMetrics.widthPixels
        tg.start()
    }
}
