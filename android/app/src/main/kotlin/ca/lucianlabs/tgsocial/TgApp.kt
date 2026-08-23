package ca.lucianlabs.tgsocial

import android.app.Application
import ca.lucianlabs.tgsocial.repo.DiscoveryRepo
import ca.lucianlabs.tgsocial.repo.FeedRepo
import ca.lucianlabs.tgsocial.repo.LocalStore
import ca.lucianlabs.tgsocial.repo.MediaRepo
import ca.lucianlabs.tgsocial.repo.MyNodeRepo
import ca.lucianlabs.tgsocial.repo.NodeRepo
import ca.lucianlabs.tgsocial.repo.PostingRepo
import ca.lucianlabs.tgsocial.td.TelegramClient

/** Process-scoped graph: one TDLib client with its collectors attached in onCreate, and the repositories over it. */
class TgApp : Application() {
    lateinit var tg: TelegramClient
        private set
    lateinit var store: LocalStore
        private set
    lateinit var nodes: NodeRepo
        private set
    lateinit var myNode: MyNodeRepo
        private set
    lateinit var feed: FeedRepo
        private set
    lateinit var discovery: DiscoveryRepo
        private set
    lateinit var posting: PostingRepo
        private set
    lateinit var media: MediaRepo
        private set

    override fun onCreate() {
        super.onCreate()
        tg = TelegramClient(this)
        store = LocalStore(this)
        nodes = NodeRepo(tg, store)
        myNode = MyNodeRepo(tg, store, nodes)
        feed = FeedRepo(tg, nodes, store)
        discovery = DiscoveryRepo(tg, nodes)
        posting = PostingRepo(this, tg)
        media = MediaRepo(tg)
        feed.displayWidthPx = resources.displayMetrics.widthPixels
        tg.start()
    }
}
