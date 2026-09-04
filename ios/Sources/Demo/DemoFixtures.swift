// Demo — the fixture world and the demo's copy (PRODUCT.md §2.22, §2.22.1).
//
// Wholly invented. Nothing here is captured from a real channel, and the captures under
// `web/test/fixtures/` are deliberately not reused: those are real people's posts.
//
// This file is DATA and pure Swift. It imports Foundation and nothing else — in particular it
// imports no TDLib symbol, which is §2.22.4's build-time guarantee that a demo session has no code
// path to Telegram to miss. `DemoSourceIsolationTests` reads these files and fails the build if a
// TDLib import appears.

import Foundation

// MARK: - Copy (PRODUCT §3: the strings are shared across the three builds, verbatim)

/// Every string the demo puts on screen. Named constants rather than literals at the call site
/// because PRODUCT §3 makes this copy shared across iOS, Android and web — three agents inventing
/// three wordings for the same control is exactly what that rule exists to prevent, and a test can
/// assert a constant.
enum DemoCopy {
    /// §2.1, step 1 only.
    static let enterButton = "Look Around First"
    static let enterMuted = "Invented people, invented posts. Nothing is sent to Telegram."

    /// The status pill, in place of §2.10's. Never gold: gold on that pill means a live Telegram
    /// connection (§1).
    static let pill = "Demo"
    /// The strip docked under the topbar, on every screen and inside the full-screen viewers.
    static let strip = "Demo. Everyone here is invented. Nothing leaves this device."

    /// Three refusals, because each names a different truth (§2.22.3).
    static let noWrite = "The demo doesn't write to Telegram."
    static let notOnTelegram = "Nothing here is on Telegram."
    static let noLinks = "Links don't open in the demo."

    /// §2.22.5, the demo sheet.
    static let sheetMark = "Demo"
    static let sheetTitle = "You're in the demo."
    static let sheetBody = "Everyone here is invented. Nothing is sent to Telegram and nothing is saved on this device. Report, block and mute are real and work on these fixtures."
    static let leaveButton = "Leave Demo"
    static let telegramRow = "Not connected"

    /// The two exits (§2.22, §2.22.2).
    static let leftToast = "Left the demo."
    static let deletedToast = "Your node is gone. The demo is over."

    /// §2.22.2's one written-down deviation from §2.15: the report email's body gains this line at
    /// the top. §2.15 says the app adds nothing else, and this is the exception — without it the
    /// operator opens their inbox and goes looking for a channel that does not exist.
    static let reportPrefix = "Demo: this report is from the demo and the link is invented."

    /// Explore's search miss, the same string a real session shows.
    static let notANode = "Not a tgsocial node."
}

// MARK: - The world

enum DemoFixtures {
    /// The reader (§2.22.1). `public: no`, so they are absent from the Directory per §2.4.
    static let reader = "tgs_demo_you"
    static let readerRepliesChannel = "tgs_demo_you_r"

    /// Every node username carries this prefix and every channel username the one below, so a
    /// single post card cropped out of context still says what it is (§2.22, indicator 3).
    static let nodePrefix = "tgs_demo_"
    static let channelPrefix = "demo_"

    struct NodeSpec {
        let username: String
        let name: String
        let bio: String
        let feeds: [String]
        let follows: [String]
        let isPublic: Bool
        /// Nil only for the reader, whose comments channel is `demo_you_r` and empty.
        let replies: String
    }

    /// Fifteen. Cast, bios, feeds and the follow graph are §2.22.1's two tables, transcribed.
    static let nodes: [NodeSpec] = [
        NodeSpec(username: "tgs_demo_you", name: "Demo Reader", bio: "Looking around.",
                 feeds: ["demo_you_notes"],
                 follows: ["tgs_demo_wren", "tgs_demo_mox", "tgs_demo_juno", "tgs_demo_pell"],
                 isPublic: false, replies: readerRepliesChannel),
        NodeSpec(username: "tgs_demo_wren", name: "Wren Alderiss", bio: "Tide clocks and bad solder.",
                 feeds: ["demo_tidewright", "demo_wren_bench"],
                 follows: ["tgs_demo_mox", "tgs_demo_arto", "tgs_demo_sable", "tgs_demo_ilka"],
                 isPublic: true, replies: "demo_wren_r"),
        NodeSpec(username: "tgs_demo_mox", name: "Mox Petrakis", bio: "Field recordings. Mostly rain.",
                 feeds: ["demo_slow_radio"],
                 follows: ["tgs_demo_juno", "tgs_demo_arto", "tgs_demo_bly"],
                 isPublic: true, replies: "demo_mox_r"),
        NodeSpec(username: "tgs_demo_juno", name: "Juno Bell-Okafor", bio: "Ceramics, mostly failures.",
                 feeds: ["demo_kiln_log"],
                 follows: ["tgs_demo_pell", "tgs_demo_wren", "tgs_demo_orrin"],
                 isPublic: true, replies: "demo_juno_r"),
        NodeSpec(username: "tgs_demo_pell", name: "Pell Nakagawa", bio: "Letterpress, one press.",
                 feeds: ["demo_press_run"],
                 follows: ["tgs_demo_sable", "tgs_demo_hask", "tgs_demo_orrin", "tgs_demo_crate"],
                 isPublic: true, replies: "demo_pell_r"),
        NodeSpec(username: "tgs_demo_arto", name: "Arto Vansi", bio: "Trail cameras on the creek.",
                 feeds: ["demo_creek_cam"], follows: [], isPublic: true, replies: "demo_arto_r"),
        NodeSpec(username: "tgs_demo_orrin", name: "Orrin Baptiste", bio: "Bread, weather, complaints.",
                 feeds: ["demo_proof_box"], follows: [], isPublic: true, replies: "demo_orrin_r"),
        NodeSpec(username: "tgs_demo_sable", name: "Sable Quiring", bio: "Maps nobody asked for.",
                 feeds: ["demo_paper_maps"], follows: [], isPublic: true, replies: "demo_sable_r"),
        NodeSpec(username: "tgs_demo_bly", name: "Bly Toussaint", bio: "Night sky, cheap lens.",
                 feeds: ["demo_dark_sky"], follows: [], isPublic: true, replies: "demo_bly_r"),
        NodeSpec(username: "tgs_demo_hask", name: "Hask Oyelaran", bio: "Fixes the ferry radio.",
                 feeds: ["demo_ferry_net"], follows: [], isPublic: true, replies: "demo_hask_r"),
        NodeSpec(username: "tgs_demo_ilka", name: "Ilka Ferreira", bio: "Bike frames.",
                 feeds: ["demo_frame_jig"], follows: [], isPublic: true, replies: "demo_ilka_r"),
        // The spam node. Reached at +1 through `pell`, so their comment is in §6.3 scope, carries
        // the `+1` pill, and is the thing a reviewer reports and blocks.
        NodeSpec(username: "tgs_demo_crate", name: "Crate Mailer", bio: "Free crates. Ask me.",
                 feeds: ["demo_free_crates"], follows: [], isPublic: true, replies: "demo_crate_r"),
        // The three in no walk: the DIRECTORY (§2.4).
        NodeSpec(username: "tgs_demo_lume", name: "Lume Adeyemi", bio: "Neon repair.",
                 feeds: ["demo_neon_bench"], follows: [], isPublic: true, replies: "demo_lume_r"),
        NodeSpec(username: "tgs_demo_noor", name: "Noor Salk", bio: "Weather balloons.",
                 feeds: ["demo_balloon_log"], follows: [], isPublic: true, replies: "demo_noor_r"),
        NodeSpec(username: "tgs_demo_veda", name: "Veda Marchetti", bio: "Sails.",
                 feeds: ["demo_sail_loft"], follows: [], isPublic: true, replies: "demo_veda_r"),
    ]

    /// The reader's card, serialised per PROTOCOL §2 — the shared vector the three builds parse, so
    /// a disagreement between platforms is a parser bug and not a fixture typo.
    static let readerCardVector = """
    tgsocial v1
    name: Demo Reader
    bio: Looking around.
    public: no
    feeds: @demo_you_notes
    follows: @tgs_demo_wren @tgs_demo_mox @tgs_demo_juno @tgs_demo_pell
    replies: @tgs_demo_you_r
    """

    struct FeedSpec {
        let username: String
        let title: String
        let owner: String
        /// The channel bio. Two carry the PROTOCOL §3 backlink so both `Verified` states are on
        /// screen; the rest do not.
        let bio: String
        let verified: Bool
        /// §2.22: two channels carry a generated plate as their photo, so §2.3's FIRST avatar
        /// fallback branch paints too. The rest fall to the initial over a seeded tint, which is
        /// §2.3's third branch reached honestly — a fixture channel has no photo.
        let hasPlate: Bool
    }

    static let feeds: [FeedSpec] = [
        FeedSpec(username: "demo_you_notes", title: "Notes", owner: "tgs_demo_you",
                 bio: "Things I write down.", verified: false, hasPlate: false),
        FeedSpec(username: "demo_tidewright", title: "Tidewright", owner: "tgs_demo_wren",
                 bio: "Tide clocks.", verified: true, hasPlate: true),
        FeedSpec(username: "demo_wren_bench", title: "Wren's bench", owner: "tgs_demo_wren",
                 bio: "What is on the bench.", verified: false, hasPlate: false),
        FeedSpec(username: "demo_slow_radio", title: "Slow Radio", owner: "tgs_demo_mox",
                 bio: "Field recordings.", verified: false, hasPlate: true),
        FeedSpec(username: "demo_kiln_log", title: "Kiln Log", owner: "tgs_demo_juno",
                 bio: "Firings, glazes, failures.", verified: true, hasPlate: false),
        FeedSpec(username: "demo_press_run", title: "Press Run", owner: "tgs_demo_pell",
                 bio: "One press, slowly.", verified: false, hasPlate: false),
        FeedSpec(username: "demo_creek_cam", title: "Creek Cam", owner: "tgs_demo_arto",
                 bio: "Trail cameras.", verified: false, hasPlate: false),
        FeedSpec(username: "demo_proof_box", title: "Proof Box", owner: "tgs_demo_orrin",
                 bio: "Bread and weather.", verified: false, hasPlate: false),
        FeedSpec(username: "demo_paper_maps", title: "Paper Maps", owner: "tgs_demo_sable",
                 bio: "Maps nobody asked for.", verified: false, hasPlate: false),
        FeedSpec(username: "demo_dark_sky", title: "Dark Sky", owner: "tgs_demo_bly",
                 bio: "Night sky, cheap lens.", verified: false, hasPlate: false),
        FeedSpec(username: "demo_ferry_net", title: "Ferry Net", owner: "tgs_demo_hask",
                 bio: "The ferry radio.", verified: false, hasPlate: false),
        FeedSpec(username: "demo_frame_jig", title: "Frame Jig", owner: "tgs_demo_ilka",
                 bio: "Bike frames.", verified: false, hasPlate: false),
        FeedSpec(username: "demo_free_crates", title: "Free Crates", owner: "tgs_demo_crate",
                 bio: "Free crates.", verified: false, hasPlate: false),
        FeedSpec(username: "demo_neon_bench", title: "Neon Bench", owner: "tgs_demo_lume",
                 bio: "Neon repair.", verified: false, hasPlate: false),
        FeedSpec(username: "demo_balloon_log", title: "Balloon Log", owner: "tgs_demo_noor",
                 bio: "Weather balloons.", verified: false, hasPlate: false),
        FeedSpec(username: "demo_sail_loft", title: "Sail Loft", owner: "tgs_demo_veda",
                 bio: "Sails.", verified: false, hasPlate: false),
    ]

    // MARK: Posts (§2.22.1)

    /// What a post carries. One case per media shape the app has to draw, so the fifteen posts
    /// cover every branch of §2.3 and §2.11 between them.
    enum Body: Equatable {
        case text
        /// 3:42, spectrogram strip. Synthesised on first play (§2.22.1 "Media is generated").
        case audio(title: String, performer: String, seconds: Int)
        /// Four photos at four aspects: mosaic on the card, carousel full-screen (§2.11.3).
        case album(aspects: [(w: Int, h: Int)])
        case photo(w: Int, h: Int)
        case linkPreview(url: String, site: String, title: String, text: String)
        case document(name: String, mime: String, bytes: Int64)
        case video(seconds: Int, w: Int, h: Int)
        /// Muted, autoplaying, 2 s loop.
        case animation(seconds: Int, w: Int, h: Int)
        /// Ships Telegram-shaped waveform bytes, so §2.11.2's draw-immediately path is the one
        /// that runs rather than the analyse-then-draw path.
        case voice(seconds: Int)

        static func == (a: Body, b: Body) -> Bool { a.tag == b.tag }
        private var tag: String {
            switch self {
            case .text: return "text"
            case .audio: return "audio"
            case .album: return "album"
            case .photo: return "photo"
            case .linkPreview: return "link"
            case .document: return "document"
            case .video: return "video"
            case .animation: return "animation"
            case .voice: return "voice"
            }
        }
    }

    struct PostSpec {
        let channel: String
        /// The SERVER message id — the number in the t.me link. TDLib's own id is this shifted
        /// left 20 bits (`DeepLink.serverMessageId`), which is what `DemoWorld` stores.
        let id: Int64
        /// Seconds before the moment the demo started. Never a fixed date: the §2.3 relative-time
        /// ladder has to read correctly in a review a year from now.
        let age: Int
        let text: String
        let body: Body
    }

    static let minute = 60, hour = 3600, day = 86_400

    /// Fifteen across six sources, newest first — the order Feed paints them. The other nine feeds
    /// belong to +1 nodes and are deliberately absent here: the merge is the follow graph, so a
    /// reviewer who opens `arto`'s profile finds posts they never saw in Feed.
    static let posts: [PostSpec] = [
        PostSpec(channel: "demo_tidewright", id: 147, age: 40,
                 text: "Tide clock is off by nine minutes and I know exactly why.", body: .text),
        PostSpec(channel: "demo_slow_radio", id: 101, age: 6 * minute,
                 text: "Three in the morning, and it did not let up.",
                 body: .audio(title: "Rain on the shed roof", performer: "Slow Radio", seconds: 222)),
        PostSpec(channel: "demo_kiln_log", id: 224, age: 22 * minute,
                 text: "Glaze tests. Two of these are the same glaze.",
                 body: .album(aspects: [(4, 3), (3, 4), (1, 1), (16, 9)])),
        PostSpec(channel: "demo_press_run", id: 72, age: 2 * hour,
                 text: "Found this while cleaning out a drawer.",
                 // example.com is reserved for exactly this (RFC 2606), and tapping it does not
                 // navigate anyway (§2.22.3).
                 body: .linkPreview(url: "https://example.com/em-dash", site: "example.com",
                                    title: "A Short History of the Em Dash",
                                    text: "Why the long dash outlived the metal it was cast in.")),
        PostSpec(channel: "demo_wren_bench", id: 17, age: 5 * hour,
                 text: "The 1971 tables, scanned. The columns drift after page four.",
                 body: .document(name: "tide-table-1971.pdf", mime: "application/pdf", bytes: 2_516_582)),
        PostSpec(channel: "demo_you_notes", id: 2, age: 9 * hour,
                 text: "Testing the demo. This one is mine.", body: .text),
        PostSpec(channel: "demo_slow_radio", id: 95, age: 14 * hour,
                 text: "The ferry leaving in fog.", body: .video(seconds: 18, w: 480, h: 270)),
        PostSpec(channel: "demo_tidewright", id: 144, age: day,
                 text: "New moon. Everything in the harbour is six inches lower than it should be.",
                 body: .text),
        PostSpec(channel: "demo_kiln_log", id: 219, age: 2 * day,
                 text: "Failure on the left.", body: .photo(w: 1, h: 1)),
        PostSpec(channel: "demo_press_run", id: 71, age: 3 * day,
                 text: "", body: .voice(seconds: 47)),
        PostSpec(channel: "demo_wren_bench", id: 12, age: 6 * day,
                 text: "Ordered the wrong solder again.", body: .text),
        PostSpec(channel: "demo_slow_radio", id: 88, age: 14 * day,
                 text: "Two seconds of the harbour light.",
                 body: .animation(seconds: 2, w: 320, h: 320)),
        PostSpec(channel: "demo_kiln_log", id: 203, age: 35 * day,
                 text: "Kiln is at cone six and holding.", body: .text),
        PostSpec(channel: "demo_press_run", id: 58, age: 120 * day,
                 text: "The press is level. It only took a year.", body: .text),
        PostSpec(channel: "demo_you_notes", id: 1, age: 730 * day,
                 text: "First post.", body: .text),
    ]

    /// Feed pages eight at a time, so Feed loads a second page and then says `That's everything.`
    /// — pagination runs, and so does §2.18's rule that a fully-filtered page fetches the next one.
    static let pageSize = 8

    // MARK: Comments (PROTOCOL §6, PRODUCT §2.12)

    struct CommentSpec {
        let channel: String
        let id: Int64
        let age: Int
        /// `<channel>/<serverId>` of what this points at — a post, or another comment.
        let target: String
        let body: String
    }

    /// Eleven, in two threads. The first has a 3-deep `re:` chain and the spam comment; the second
    /// is one chain six deep, so §2.12's depth-5 cap flattens its last row.
    static let comments: [CommentSpec] = [
        CommentSpec(channel: "demo_mox_r", id: 31, age: 22 * hour, target: "demo_tidewright/144",
                    body: "Six inches is the whole reason I stopped trusting that gauge."),
        CommentSpec(channel: "demo_wren_r", id: 40, age: 21 * hour, target: "demo_mox_r/31",
                    body: "The gauge is fine. The pier moved."),
        CommentSpec(channel: "demo_mox_r", id: 32, age: 20 * hour, target: "demo_wren_r/40",
                    body: "Then the pier moved."),
        CommentSpec(channel: "demo_juno_r", id: 9, age: 19 * hour, target: "demo_tidewright/144",
                    body: "Photograph the pier or it didn't happen."),
        CommentSpec(channel: "demo_crate_r", id: 12, age: 18 * hour, target: "demo_tidewright/144",
                    body: "FREE CRATES today only, message me for the link."),

        CommentSpec(channel: "demo_wren_r", id: 41, age: 47 * hour, target: "demo_kiln_log/219",
                    body: "Which one is the failure?"),
        CommentSpec(channel: "demo_juno_r", id: 10, age: 46 * hour, target: "demo_wren_r/41",
                    body: "Both."),
        CommentSpec(channel: "demo_wren_r", id: 42, age: 45 * hour, target: "demo_juno_r/10",
                    body: "Then it worked."),
        CommentSpec(channel: "demo_juno_r", id: 11, age: 44 * hour, target: "demo_wren_r/42",
                    body: "It cracked."),
        CommentSpec(channel: "demo_mox_r", id: 33, age: 43 * hour, target: "demo_juno_r/11",
                    body: "It always cracks."),
        CommentSpec(channel: "demo_wren_r", id: 43, age: 42 * hour, target: "demo_mox_r/33",
                    body: "Agreed."),
    ]

    // MARK: Derived numbers

    /// Reactions and views DERIVE from the message id rather than being invented per row, so all
    /// three builds print the same figures without a fourth table to keep in step (§2.22.1).
    static func reactionCount(id: Int64) -> Int { Int((id &* 7) % 23) }
    static func viewCount(id: Int64) -> Int { 60 + Int((id &* 37) % 900) }
}
