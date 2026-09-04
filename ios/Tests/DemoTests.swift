// Tests — the demo (PRODUCT.md §2.22).
//
// Every test here measures something a reviewer or a reader can see: a number on screen, a string
// in a toast, a file that decodes, a record that did or did not reach disk. Nothing asserts that a
// function was called.
//
// The model is built directly. That is newly possible and is itself part of §2.22.4: `TDClient`
// makes its handle on first use, so an `AppModel` that only ever enters the demo never constructs
// one — which is the same reason the app can enter the demo without booting TDLib, exercised here.

import AVFoundation
import CoreGraphics
import UIKit
import XCTest
@testable import tgsocial

@MainActor
final class DemoWorldTests: XCTestCase {

    // MARK: The follow graph, as it appears on Graph and Explore (§2.22.1)

    func testGraphCountsAreFourDirectAndSevenAtPlusOne() {
        let world = DemoWorld()
        XCTAssertEqual(world.direct.count, 4, "Graph reads DIRECT · 4")
        XCTAssertEqual(world.nearby.count, 7, "Graph reads +1 · 7")
        XCTAssertEqual(world.networkRow, "4 direct \u{00B7} 7 at +1")
    }

    /// §2.22.1 writes the NEARBY order down precisely because three platforms breaking ties three
    /// ways is three different demos: mutual count descending, then username ascending.
    func testNearbyRanksByMutualCountThenUsername() {
        let world = DemoWorld()
        XCTAssertEqual(world.nearby.map(\.node.username),
                       ["tgs_demo_arto", "tgs_demo_orrin", "tgs_demo_sable",
                        "tgs_demo_bly", "tgs_demo_crate", "tgs_demo_hask", "tgs_demo_ilka"])
        XCTAssertEqual(world.nearby.prefix(3).map(\.followedByCount), [2, 2, 2])
        XCTAssertEqual(world.nearby.suffix(4).map(\.followedByCount), [1, 1, 1, 1])
    }

    /// The three nodes in no walk, and — because the reader is `public: no` (§2.4) — not the reader.
    func testDirectoryIsTheThreeNodesInNoWalk() {
        let world = DemoWorld()
        XCTAssertEqual(world.directory.map(\.node.username).sorted(),
                       ["tgs_demo_lume", "tgs_demo_noor", "tgs_demo_veda"])
        XCTAssertFalse(world.directory.contains { $0.node.username == DemoFixtures.reader },
                       "the reader is public: no, so §2.4 keeps them out of the Directory")
    }

    /// The reader's card is given in the spec as a literal PROTOCOL §2 vector so three parsers
    /// agree. Parsing it must yield the card the world actually runs on.
    func testReaderCardMatchesTheSharedVector() {
        guard case .card(let parsed) = CardCodec.parse(DemoFixtures.readerCardVector) else {
            return XCTFail("the reader's vector does not parse as a v1 card")
        }
        let world = DemoWorld()
        XCTAssertEqual(parsed.name, world.myCard.name)
        XCTAssertEqual(parsed.bio, world.myCard.bio)
        XCTAssertEqual(parsed.isPublic, false)
        XCTAssertEqual(parsed.isPublic, world.myCard.isPublic)
        XCTAssertEqual(parsed.feeds, world.myCard.feeds)
        XCTAssertEqual(parsed.follows, world.myCard.follows)
        XCTAssertEqual(parsed.replies, world.myCard.replies)
    }

    func testEveryFixtureNamesItself() {
        for node in DemoFixtures.nodes {
            XCTAssertTrue(node.username.hasPrefix(DemoFixtures.nodePrefix), node.username)
        }
        for feed in DemoFixtures.feeds {
            XCTAssertTrue(feed.username.hasPrefix(DemoFixtures.channelPrefix), feed.username)
        }
    }

    /// Both `Verified` states have to be on screen (§2.22.1), so exactly the two named channels
    /// carry the PROTOCOL §3 backlink and the rest do not.
    func testTwoFeedsAreVerifiedAndTheRestAreNot() {
        let world = DemoWorld()
        let verified = DemoFixtures.feeds.filter { spec in
            guard let info = world.feed(spec.username) else { return false }
            return info.isVerified(for: spec.owner)
        }.map(\.username)
        XCTAssertEqual(verified.sorted(), ["demo_kiln_log", "demo_tidewright"])
    }

    // MARK: The posts (§2.22.1)

    func testFifteenPostsAcrossSixSources() {
        let world = DemoWorld()
        XCTAssertEqual(world.posts.count, 15)
        XCTAssertEqual(Set(world.posts.map(\.sourceKey)).count, 6)
        XCTAssertEqual(world.feedsRow, "6 sources \u{00B7} 15 posts")
    }

    /// The +1 nodes' feeds are deliberately absent from the main feed — the merge is the follow
    /// graph — but their channels are real, so opening `arto`'s feed finds posts Feed never showed.
    func testPlusOneFeedsAreNotInTheMainFeedButTheirChannelsHavePosts() {
        let world = DemoWorld()
        XCTAssertFalse(world.posts.contains { $0.sourceKey == "demo_creek_cam" })
        let page = world.channelPage("demo_creek_cam", after: 0)
        XCTAssertFalse(page.posts.isEmpty, "a +1 node's channel is not an empty screen")
        XCTAssertTrue(page.exhausted)
    }

    /// Every rung of §2.3's ladder is on the list, so a wrong rounding is visible without
    /// arithmetic — which is a promise about the fifteen numbers on the cards, not about the table.
    ///
    /// So this renders through the clock the card renders through: `PostHeader` reads
    /// `TimelineView(.everyMinute)`, whose `context.date` is the last minute boundary and therefore
    /// trails the instant the demo was entered by however far into the minute that was. The `now`
    /// here is computed from the entry instant rather than read off `world.startedAt`, so a world
    /// anchored to the instant instead of the boundary fails: every fixture age is an exact multiple
    /// of its unit, and floor rounding against a lagging clock paints one rung low.
    func testEveryRungOfTheLadderPaintsAsTabulatedForTheWholeFirstMinute() {
        // §2.22.1's table, newest first — the order Feed paints them.
        let tabulated = ["now", "6m ago", "22m ago", "2h ago", "5h ago", "9h ago", "14h ago",
                         "1d ago", "2d ago", "3d ago", "6d ago", "2w ago", "5w ago", "4mo ago", "2y ago"]
        for secondsIntoTheMinute in 0...59 {
            let entered = Date(timeIntervalSince1970: 1_772_000_000 + Double(secondsIntoTheMinute))
            let world = DemoWorld(now: entered)
            let tick = Date(timeIntervalSince1970: (entered.timeIntervalSince1970 / 60).rounded(.down) * 60)
            let rendered = world.posts.map { PostTime.relative(unix: $0.date, now: tick) }
            XCTAssertEqual(rendered, tabulated,
                           "entered \(secondsIntoTheMinute)s into the minute")
        }
    }

    /// Reactions and views DERIVE from the message id (§2.22.1) so all three builds print the same
    /// figures. `demo_tidewright/147`: 147×7 mod 23 = 9; 60 + 147×37 mod 900 = 60 + 39 = 99.
    func testReactionsAndViewsDeriveFromTheMessageId() {
        XCTAssertEqual(DemoFixtures.reactionCount(id: 147), (147 * 7) % 23)
        XCTAssertEqual(DemoFixtures.viewCount(id: 147), 60 + (147 * 37) % 900)
        let world = DemoWorld()
        guard let post = world.posts.first(where: { $0.sourceKey == "demo_tidewright"
            && DeepLink.serverMessageId($0.messageId) == 147 }) else {
            return XCTFail("demo_tidewright/147 is missing")
        }
        XCTAssertEqual(post.views, DemoFixtures.viewCount(id: 147))
        XCTAssertEqual(post.reactions.first?.count, DemoFixtures.reactionCount(id: 147))
    }

    /// Eight at a time, so Feed loads a second page and then says `That's everything.`
    func testFeedPagesEightThenExhausts() {
        let world = DemoWorld()
        let first = world.page(upTo: DemoFixtures.pageSize)
        XCTAssertEqual(first.posts.count, 8)
        XCTAssertFalse(first.exhausted)
        let second = world.page(upTo: DemoFixtures.pageSize * 2)
        XCTAssertEqual(second.posts.count, 15)
        XCTAssertTrue(second.exhausted)
    }

    /// The album is four messages, which is what makes paging the carousel re-target the thread
    /// (§2.12) — `ViewerRequest.links(of:)` tests exactly this shape.
    func testTheAlbumIsFourItemsAtFourAspectsWithFourMessageIds() {
        let world = DemoWorld()
        guard let album = world.posts.first(where: { $0.sourceKey == "demo_kiln_log" && $0.media.count == 4 }) else {
            return XCTFail("the four-photo album is missing")
        }
        XCTAssertEqual(album.albumMessageIds.count, 4)
        XCTAssertEqual(Set(album.albumMessageIds).count, 4)
        var aspects: [Double] = []
        for item in album.media {
            guard case .photo(_, let full) = item else { return XCTFail("album item is not a photo") }
            aspects.append((Double(full.width) / Double(full.height) * 100).rounded() / 100)
        }
        XCTAssertEqual(Set(aspects).count, 4, "four aspects, so the mosaic has all four shapes: \(aspects)")
        XCTAssertEqual(ViewerRequest.links(of: album).count, 4)
    }

    func testTheVoiceNoteShipsWaveformBytesSoTheStripDrawsImmediately() {
        let world = DemoWorld()
        let voice = world.posts.compactMap { post -> (Int, Data)? in
            for item in post.media { if case .voice(_, let duration, let bytes) = item { return (duration, bytes) } }
            return nil
        }
        XCTAssertEqual(voice.count, 1)
        XCTAssertEqual(voice.first?.0, 47)
        let decoded = WaveformCodec.decode(voice.first?.1 ?? Data())
        XCTAssertGreaterThanOrEqual(decoded.count, 32)
        XCTAssertTrue(decoded.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertGreaterThan(decoded.max() ?? 0, 0.5, "a flat waveform has no silhouette to draw")
    }

    /// The link preview points at `example.com` — reserved for this by RFC 2606 — so the one host
    /// in the demo is a host nobody owns.
    func testTheLinkPreviewUsesAReservedHost() {
        let world = DemoWorld()
        let hosts = world.posts.flatMap { $0.media.compactMap { item -> String? in
            if case .linkPreview(let url, _, _, _, _) = item { return URL(string: url)?.host }
            return nil
        } }
        XCTAssertEqual(hosts, ["example.com"])
    }

    // MARK: Comments (§2.22.1, PROTOCOL §6)

    func testTheTwoThreadsCarryFiveAndSixComments() {
        let world = DemoWorld()
        let onTidewright = CommentRepository.comments(forTargets: ["https://t.me/demo_tidewright/144"],
                                                      in: world.commentIndex)
        XCTAssertEqual(onTidewright.count, 5)
        let onKiln = CommentRepository.comments(forTargets: ["https://t.me/demo_kiln_log/219"],
                                                in: world.commentIndex)
        XCTAssertEqual(onKiln.count, 6)
        XCTAssertEqual(DemoFixtures.comments.count, 11)
    }

    /// `crate` is reached at +1 through `pell`, so their comment is in §6.3 scope and wears the
    /// `+1` pill; everyone else in the thread is a direct follow and does not.
    func testOnlyTheSpamCommentCarriesThePlusOnePill() {
        let world = DemoWorld()
        let thread = CommentRepository.comments(forTargets: ["https://t.me/demo_tidewright/144"],
                                                in: world.commentIndex)
        let plusOne = thread.filter(\.isPlusOne).map(\.ownerUsername)
        XCTAssertEqual(plusOne, ["tgs_demo_crate"])
    }

    /// One chain six deep, so §2.12's depth-5 cap flattens its last row rather than indenting past
    /// the cap. Asserted on the rendered tree, which is what a reader sees.
    func testTheSixDeepChainIsFlattenedAtTheDepthCap() {
        let world = DemoWorld()
        let thread = CommentRepository.comments(forTargets: ["https://t.me/demo_kiln_log/219"],
                                                in: world.commentIndex)
        let rows = CommentTree.rows(comments: thread, roots: ["https://t.me/demo_kiln_log/219"])
        XCTAssertEqual(rows.count, 6)
        // Depths run 0…4 and then stop: the sixth row shares the fifth's indent rather than
        // stepping past the cap, which is §2.12's flattening made visible.
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 3, CommentCodec.maxDepth - 1, CommentCodec.maxDepth - 1])
    }

    /// The reader has never commented, and commenting is a write (§2.22.3) — so §2.12's
    /// `YOUR COMMENTS CHANNEL` first-comment card never appears, because the card *does* exist.
    func testTheReadersCommentsChannelExistsAndIsEmpty() {
        let world = DemoWorld()
        XCTAssertEqual(world.myCard.replies, DemoFixtures.readerRepliesChannel)
        let mine = world.commentIndex.values.flatMap { $0 }.filter(\.isMine)
        XCTAssertTrue(mine.isEmpty)
    }

    // MARK: Copy (PRODUCT §3 makes it shared across the three builds)

    func testTheDemoStringsAreTheOnesTheSpecWritesDown() {
        XCTAssertEqual(DemoCopy.enterButton, "Look Around First")
        XCTAssertEqual(DemoCopy.enterMuted, "Invented people, invented posts. Nothing is sent to Telegram.")
        XCTAssertEqual(DemoCopy.pill, "Demo")
        XCTAssertEqual(DemoCopy.strip, "Demo. Everyone here is invented. Nothing leaves this device.")
        XCTAssertEqual(DemoCopy.noWrite, "The demo doesn't write to Telegram.")
        XCTAssertEqual(DemoCopy.notOnTelegram, "Nothing here is on Telegram.")
        XCTAssertEqual(DemoCopy.noLinks, "Links don't open in the demo.")
        XCTAssertEqual(DemoCopy.sheetTitle, "You're in the demo.")
        XCTAssertEqual(DemoCopy.leaveButton, "Leave Demo")
        XCTAssertEqual(DemoCopy.leftToast, "Left the demo.")
        XCTAssertEqual(DemoCopy.deletedToast, "Your node is gone. The demo is over.")
        XCTAssertEqual(StatusKind.demo.label, "Demo")
    }

    /// §3's banned words for this feature. The demo is called `demo` everywhere, never one of the
    /// four things §3 names it is not.
    func testTheDemoIsNeverCalledSandboxSampleTestModeOrFake() {
        let strings = [DemoCopy.enterButton, DemoCopy.enterMuted, DemoCopy.pill, DemoCopy.strip,
                       DemoCopy.noWrite, DemoCopy.notOnTelegram, DemoCopy.noLinks,
                       DemoCopy.sheetMark, DemoCopy.sheetTitle, DemoCopy.sheetBody,
                       DemoCopy.leaveButton, DemoCopy.leftToast, DemoCopy.deletedToast,
                       DemoCopy.reportPrefix]
        for banned in ["sandbox", "sample", "test mode", "fake"] {
            for text in strings {
                XCTAssertFalse(text.lowercased().contains(banned), "\"\(text)\" says \(banned)")
            }
        }
    }
}

// MARK: - Generated media (§2.22.1, §2.22.4)

@MainActor
final class DemoMediaTests: XCTestCase {

    /// "Media cannot reach the network because fixture media has no file id." Every id in the world
    /// is in the demo range, and TDLib's ids are positive, so the two cannot be confused.
    func testEveryFixtureFileIdIsOutsideTDLibsRange() {
        let world = DemoWorld()
        var ids: [Int] = []
        func collect(_ media: [PostMedia]) {
            for item in media {
                switch item {
                case .photo(let preview, let full): ids += [preview.fileId, full.fileId]
                case .video(let f, let t, _, _, _), .animation(let f, let t, _, _, _):
                    ids.append(f.fileId); if let t { ids.append(t.fileId) }
                case .audio(let f, _, _, _): ids.append(f.fileId)
                case .voice(let f, _, _): ids.append(f.fileId)
                case .videoNote(let f, let t, _): ids.append(f.fileId); if let t { ids.append(t.fileId) }
                case .document(let f, let t): ids.append(f.fileId); if let t { ids.append(t.fileId) }
                case .sticker(let f, let t, _, _, _, _): ids.append(f.fileId); if let t { ids.append(t.fileId) }
                case .linkPreview(_, _, _, _, let t): if let t { ids.append(t.fileId) }
                case .summary: break
                }
            }
        }
        for post in world.posts { collect(post.media) }
        for feed in DemoFixtures.feeds { if let photo = world.feed(feed.username)?.photo { ids.append(photo.fileId) } }
        XCTAssertFalse(ids.isEmpty)
        for id in ids {
            XCTAssertTrue(DemoMedia.isDemoFileId(id), "file id \(id) is not in the demo range")
            XCTAssertLessThan(id, 0, "TDLib file ids are positive; a fixture's must not be")
        }
    }

    /// A plate is deterministic from its key and carries pixels — two plates from the same key are
    /// the same image, two from different keys are not.
    func testPlatesAreDeterministicPerKeyAndDifferPerKey() {
        let a = DemoRender.plate(key: "demo_kiln_log/224-1", width: 120, height: 90)
        let again = DemoRender.plate(key: "demo_kiln_log/224-1", width: 120, height: 90)
        let other = DemoRender.plate(key: "demo_kiln_log/224-2", width: 120, height: 90)
        XCTAssertEqual(a.size, CGSize(width: 120, height: 90))
        XCTAssertEqual(a.pngData(), again.pngData(), "the same key must paint the same plate")
        XCTAssertNotEqual(a.pngData(), other.pngData(), "different keys must not paint the same plate")
    }

    /// The synthesised clip has to have something for §2.11.1 to draw: broadband under the sweep,
    /// and a level that moves. A rectangle would give the one-pole envelope no silhouette.
    func testSynthesisedAudioHasASweepThatRisesAboveTheBed() {
        let samples = DemoRender.audioSamples(key: "demo_slow_radio/101", seconds: 40)
        XCTAssertEqual(samples.count, Int(DemoRender.sampleRate) * 40)
        func peak(from: Double, to: Double) -> Int {
            let lo = Int(from * DemoRender.sampleRate), hi = min(Int(to * DemoRender.sampleRate), samples.count)
            return samples[lo..<hi].map { Int(abs(Int32($0))) }.max() ?? 0
        }
        let bed = peak(from: 15, to: 25)
        let sweep = peak(from: 31, to: 37)
        XCTAssertGreaterThan(bed, 0, "the noise bed is not silence")
        XCTAssertGreaterThan(sweep, bed * 2, "the sweep has to stand out of the bed: \(sweep) vs \(bed)")
    }

    /// The strip reads the file with `AVAudioFile`, so the generated header has to be one it opens.
    func testGeneratedAudioIsAFileTheSpectrogramCanRead() async throws {
        let media = DemoMedia()
        defer { media.discard() }
        let ref = media.audio(key: "demo_press_run/71", seconds: 2)
        let generated = await media.path(fileId: ref.fileId)
        let path = try XCTUnwrap(generated)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        XCTAssertEqual(file.processingFormat.sampleRate, DemoRender.sampleRate)
        XCTAssertGreaterThan(file.length, 0)
        XCTAssertGreaterThan(media.size(fileId: ref.fileId), 0)
    }

    /// A generated document has to be a document the in-app viewer can open (§2.11).
    func testGeneratedDocumentIsAReadablePDF() async throws {
        let media = DemoMedia()
        defer { media.discard() }
        let ref = media.document(key: "demo_wren_bench/17", name: "tide-table-1971.pdf",
                                 bytes: 2_516_582, mimeType: "application/pdf")
        XCTAssertEqual(DocumentKind.of(mimeType: ref.mimeType, fileName: ref.fileName), .pdf)
        let generated = await media.path(fileId: ref.fileId)
        let path = try XCTUnwrap(generated)
        let document = try XCTUnwrap(CGPDFDocument(URL(fileURLWithPath: path) as CFURL))
        XCTAssertEqual(document.numberOfPages, 3)
    }

    /// `discard()` is "nothing is saved on this device" (§2.22.5) applied to the bytes the
    /// generators wrote: leaving the demo takes the directory with it.
    func testDiscardRemovesEveryGeneratedByte() async throws {
        let media = DemoMedia()
        let ref = media.photo(key: "demo_kiln_log/219", width: 40, height: 40)
        let generated = await media.path(fileId: ref.fileId)
        let path = try XCTUnwrap(generated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        media.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.directory.path))
    }
}

// MARK: - The demo as a state of the model

@MainActor
final class DemoModelTests: XCTestCase {

    private func enteredDemo() -> AppModel {
        let model = AppModel()
        model.enterDemo()
        return model
    }

    /// §2.22.4's first mechanism: "TDLib is never created." A model that only enters the demo never
    /// builds a client, which is exactly why the app can offer the demo on the sign-in screen.
    func testEnteringTheDemoNeverConstructsATDLibClient() {
        let model = AppModel()
        XCTAssertFalse(model.td.isStarted, "the client is built on first use, not at launch")
        model.enterDemo()
        XCTAssertTrue(model.isDemo)
        XCTAssertFalse(model.td.isStarted, "the demo must not bring a client up behind the fixtures")
    }

    func testEnteringTheDemoLandsOnFeedWithTheFirstPage() {
        let model = enteredDemo()
        XCTAssertEqual(model.tab, .feed)
        XCTAssertTrue(model.path.isEmpty)
        XCTAssertEqual(model.posts.count, DemoFixtures.pageSize)
        XCTAssertFalse(model.feedExhausted)
        XCTAssertEqual(model.status, .demo)
        XCTAssertEqual(model.myNode?.username, DemoFixtures.reader)
    }

    func testLoadingMoreReachesEveryPostAndThenExhausts() async {
        let model = enteredDemo()
        await model.loadMoreFeed()
        XCTAssertEqual(model.posts.count, 15)
        XCTAssertTrue(model.feedExhausted, "so Feed says `That's everything.`")
    }

    // MARK: §2.22.2 — the filter is checkable by counting

    /// Every number in this test is one §2.22.2 names, because "it is checkable by counting" is a
    /// claim about what a reviewer sees, not about the filter's internals.
    func testBlockingTheSpamNodeChangesThreeCountsOnScreen() async {
        let model = enteredDemo()
        await model.refreshDiscovery()
        guard let post = model.posts.first(where: {
            $0.sourceKey == "demo_tidewright" && DeepLink.serverMessageId($0.messageId) == 144
        }) else { return XCTFail("demo_tidewright/144 is not on the first page") }

        XCTAssertEqual(model.commentCount(for: post), 5)
        XCTAssertEqual(model.visibleNearby.count, 7)

        model.block("tgs_demo_crate")

        XCTAssertEqual(model.commentCount(for: post), 4, "the post footer goes 5 comments → 4")
        XCTAssertEqual(model.visibleNearby.count, 6, "Graph goes +1 · 7 → +1 · 6")
        XCTAssertFalse(model.visibleNearby.contains { $0.node.username == "tgs_demo_crate" },
                       "and the crate row is out of Explore's NEARBY")
    }

    /// Mute applies to the main feed and only there: the muted channel's own screen stays complete
    /// (§2.17), which is the difference between mute and block made visible.
    func testMutingSlowRadioTakesTheFeedFromFifteenToTwelveButNotItsOwnScreen() async {
        let model = enteredDemo()
        await model.loadMoreFeed()
        XCTAssertEqual(model.visiblePosts.count, 15)

        model.mute(feed: "demo_slow_radio", title: "Slow Radio")

        XCTAssertEqual(model.visiblePosts.count, 12, "three Slow Radio posts leave the main feed")
        let channel = await model.loadChannel(username: "demo_slow_radio", loaded: 0, cursor: 0, reset: true)
        XCTAssertEqual(model.visible(posts: channel?.posts ?? []).count, 3,
                       "the channel's own screen stays complete")
    }

    func testUnblockingPutsTheRowsBack() async {
        let model = enteredDemo()
        await model.refreshDiscovery()
        model.block("tgs_demo_crate")
        XCTAssertEqual(model.visibleNearby.count, 6)
        model.unblock("tgs_demo_crate")
        XCTAssertEqual(model.visibleNearby.count, 7, "every surface repaints on the next render")
    }

    /// PROTOCOL §7.1: "a `userId: null` record MUST NOT be written to any of the three homes", and
    /// "a demo session MUST NOT load the stored record". Both directions, measured on the file.
    func testTheDemosSafetyListsHaveNoHomeAndDoNotReadTheStoredOne() {
        let store = LocalStore()
        let before = store.load(SafetyLists.self, LocalStore.moderation)

        let model = AppModel()
        model.enterDemo()
        XCTAssertTrue(model.moderation.lists.blocked.isEmpty,
                      "a real block list is not a demo's to show")
        model.block("tgs_demo_crate")
        model.mute(feed: "demo_slow_radio", title: "Slow Radio")
        XCTAssertEqual(model.moderation.lists.blocked, ["tgs_demo_crate"])
        XCTAssertEqual(model.moderation.lists.userId, ModerationStore.noUserId)

        let after = store.load(SafetyLists.self, LocalStore.moderation)
        XCTAssertEqual(before, after, "the demo wrote to moderation.json")
        XCTAssertFalse(after?.blocked.contains("tgs_demo_crate") ?? false)
    }

    // MARK: §2.22.3 — what is disabled, and how it answers

    func testEveryWriteAnswersWithTheSameLineAndChangesNothing() async {
        let model = enteredDemo()
        let card = model.myCard

        let checks: [(String, () async -> Void)] = [
            ("Post", { _ = await model.post(text: "hello", photoPath: nil, to: "demo_you_notes") }),
            ("Follow", { await model.follow("tgs_demo_lume") }),
            ("Unfollow", { await model.unfollow("tgs_demo_wren") }),
            ("Edit Card", { _ = await model.editCard(name: "Someone Else", bio: "", link: "") }),
            ("Save Feeds", { _ = await model.saveFeeds([]) }),
            ("Public listing", { await model.setPublic(true) }),
            ("Announce", { await model.announce() }),
            ("Create Node", { _ = await model.createNode(username: "tgs_demo_new") }),
            ("Make Channel", { _ = await model.makeCommentsChannel(username: "tgs_demo_you_r") }),
        ]
        for (name, run) in checks {
            model.toast = nil
            await run()
            XCTAssertEqual(model.toast?.text, DemoCopy.noWrite, "\(name) did not name the boundary")
            XCTAssertEqual(model.myCard, card, "\(name) changed the card")
        }
    }

    func testCommentAndReplyRefuseWithoutOpeningTheComposer() {
        let model = enteredDemo()
        guard let post = model.posts.first else { return XCTFail("no posts") }
        model.startComment(on: post)
        XCTAssertEqual(model.toast?.text, DemoCopy.noWrite)
        XCTAssertNil(model.modal, "the composer must not open on a write the demo refuses")
    }

    /// Three strings, because each names a different truth (§2.22.3).
    func testTheThreeRefusalsAreToldApart() {
        let model = enteredDemo()
        model.openInTelegram("https://t.me/demo_tidewright/147")
        XCTAssertEqual(model.toast?.text, DemoCopy.notOnTelegram)

        model.copyLink("https://t.me/demo_tidewright")
        XCTAssertEqual(model.toast?.text, DemoCopy.notOnTelegram)

        model.refuseShareInDemo()
        XCTAssertEqual(model.toast?.text, DemoCopy.notOnTelegram)

        model.open("https://example.com/em-dash")
        XCTAssertEqual(model.toast?.text, DemoCopy.noLinks)
    }

    func testCopyLinkPutsNothingOnTheClipboardInTheDemo() {
        UIPasteboard.general.string = "untouched"
        let model = enteredDemo()
        model.copyLink("https://t.me/demo_tidewright")
        XCTAssertEqual(UIPasteboard.general.string, "untouched")
    }

    // MARK: §2.22.2 — report, and §2.15's one written-down deviation

    func testAReportFromTheDemoLeadsWithTheLineThatSaysSo() {
        let subject = ReportSubject(post: Post(messageId: 144 << 20, chatId: -1, sourceKey: "demo_tidewright",
                                               sourceUsername: "demo_tidewright", sourceTitle: "Tidewright",
                                               sourcePhoto: nil, date: 0, text: .empty, media: [],
                                               albumId: 0, albumMessageIds: [], views: 0, reactions: []))
        let plain = ReportMail.body(subject: subject, reason: "Spam", app: "tgsocial 1.0.0 (1) \u{00B7} iOS")
        let demo = ReportMail.body(subject: subject, reason: "Spam", app: "tgsocial 1.0.0 (1) \u{00B7} iOS",
                                   prefix: DemoCopy.reportPrefix)
        XCTAssertFalse(plain.hasPrefix(DemoCopy.reportPrefix), "§2.15: the app adds nothing else")
        XCTAssertTrue(demo.hasPrefix(DemoCopy.reportPrefix + "\n"))
        XCTAssertEqual(demo.dropFirst(DemoCopy.reportPrefix.count + 1), plain[...],
                       "the demo adds one line and changes nothing else")
    }

    /// Reporting hides the item immediately and unconditionally, in the demo as everywhere else
    /// (§2.15), and it lands in Settings → HIDDEN.
    func testReportingInTheDemoHidesTheItemAndListsIt() {
        let model = enteredDemo()
        guard let post = model.posts.first else { return XCTFail("no posts") }
        let before = model.visiblePosts.count
        model.sendReport(ReportSubject(post: post), reason: "Spam")
        XCTAssertEqual(model.visiblePosts.count, before - 1)
        XCTAssertEqual(model.moderation.lists.hidden.map(\.reason), ["Spam"])
        model.unhide(model.moderation.lists.hidden[0])
        XCTAssertEqual(model.visiblePosts.count, before)
    }

    // MARK: §2.22.2 — Delete My Node, the reason the demo is visible at all

    /// Guideline 5.1.1(v) wants an in-app way to delete the account, and `Delete My Node` sits
    /// behind a Telegram sign-in. This is the route that needs no account — so it has to end the
    /// way §2.22.2 says, with its own toast, and with the demo over.
    func testDeleteMyNodeEndsTheDemoWithItsOwnToast() async {
        let model = enteredDemo()
        XCTAssertTrue(Moderation.confirmsDelete("@tgs_demo_you", username: model.myNode?.username ?? ""),
                      "the type-to-confirm accepts the fixture username")
        let result = await model.deleteMyNode()
        XCTAssertEqual(result, .deleted)
        XCTAssertFalse(model.isDemo, "a demo has no session to survive the delete")
        XCTAssertEqual(model.toast?.text, DemoCopy.deletedToast)
        XCTAssertNil(model.myNode)
        XCTAssertTrue(model.posts.isEmpty)
    }

    // MARK: Leaving (§2.22)

    /// Leaving returns to §2.1 and puts the reader's own record back. The client restart is not
    /// exercised here on purpose — there is none to restart, which is the property
    /// `testEnteringTheDemoNeverConstructsATDLibClient` asserts.
    func testLeavingClearsTheWorldAndRestoresTheReadersOwnLists() {
        let model = enteredDemo()
        model.block("tgs_demo_crate")
        model.leaveDemo()

        XCTAssertFalse(model.isDemo)
        XCTAssertEqual(model.toast?.text, DemoCopy.leftToast)
        XCTAssertNil(model.myNode)
        XCTAssertNil(model.myCard)
        XCTAssertTrue(model.posts.isEmpty)
        XCTAssertTrue(model.nearby.isEmpty)
        XCTAssertTrue(model.directory.isEmpty)
        XCTAssertNotEqual(model.status, .demo)
        XCTAssertFalse(model.moderation.lists.blocked.contains("tgs_demo_crate"),
                       "a demo block is not the reader's judgement about a real person")
        XCTAssertFalse(model.moderation.isDemo)
    }

    /// §2.22.5: the demo is droppable and re-enterable — "relaunching leaves the demo", and a
    /// reviewer who leaves to look at sign-in and comes back must find a player that works.
    ///
    /// `DemoMedia` counts its ids down from `firstFileId` for every world and registration is
    /// deterministic, so the second demo asks for exactly the ids the first one completed. A loader
    /// that kept those `FileState`s answers with paths `discard()` deleted and never reaches the
    /// generator again — permanently, for the process, and only for the media with no second cache:
    /// audio, video, the animation and the document. Images survive on `uniqueId` and hide it.
    func testAudioIsGeneratedAgainAfterLeavingAndReenteringTheDemo() async throws {
        let model = enteredDemo()
        let first = try XCTUnwrap(Self.audioFileId(model), "the demo's audio post is the one at 6m")
        let firstGenerated = await model.media.download(first, priority: MediaLoader.tappedPriority,
                                                       label: "Downloading audio")
        let firstPath = try XCTUnwrap(firstGenerated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPath))

        model.leaveDemo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPath),
                       "leaving takes the generated bytes with it (§2.22.5)")

        model.enterDemo()
        let second = try XCTUnwrap(Self.audioFileId(model))
        XCTAssertEqual(second, first, "the second world hands out the same file id — that is the trap")
        let secondGenerated = await model.media.download(second, priority: MediaLoader.tappedPriority,
                                                        label: "Downloading audio")
        let secondPath = try XCTUnwrap(secondGenerated,
                                       "the second demo's audio has to be generated again, not served from a deleted path")
        XCTAssertNotEqual(secondPath, firstPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondPath),
                      "a path the player is handed has to be a file that exists")
        XCTAssertTrue(model.media.state(second).complete)
        model.leaveDemo()
    }

    private static func audioFileId(_ model: AppModel) -> Int? {
        for post in model.posts {
            for item in post.media {
                if case .audio(let file, _, _, _) = item { return file.fileId }
            }
        }
        return nil
    }

    // MARK: §2.2's feeds card inside the demo (§2.22.3)

    /// Manage feeds is three taps from Feed, and `candidates = []` painted §2.2's empty state —
    /// `No channels you can post to.` — one tap after You lists `Notes @demo_you_notes` and six
    /// posts after the reader's own post to it. It also took the per-feed toggle and its `Verify`
    /// off the screen, which §2.22.3 says stay and refuse.
    func testManageFeedsListsTheReadersFeedAndItsVerifyRefuses() async {
        let model = enteredDemo()
        XCTAssertEqual(model.candidates.map(\.username), ["demo_you_notes"])
        XCTAssertEqual(model.candidates.first?.title, "Notes")
        XCTAssertTrue(model.candidates.first?.isPublic ?? false, "a row with no username has no toggle")

        // The card re-queries on open. In the demo that query runs nothing — and must not blank
        // the rows it would otherwise replace.
        await model.loadCandidates()
        XCTAssertEqual(model.candidates.map(\.username), ["demo_you_notes"])

        guard let candidate = model.candidates.first else { return XCTFail("no candidate row") }
        model.toast = nil
        let verified = await model.verifyFeed(candidate)
        XCTAssertFalse(verified)
        XCTAssertEqual(model.toast?.text, DemoCopy.noWrite, "`Verify` is on §2.22.3's list")
        XCTAssertEqual(model.candidates.first?.description, candidate.description,
                       "a refused Verify does not append the backlink")
    }

#if targetEnvironment(macCatalyst)
    /// The Connector tab is in `Tab.allCases` on Catalyst and the demo shows the tabs, so every
    /// switch on §2.14's screen is reachable from inside the demo. Each one ends in
    /// `connector.json` — the home of a grant that belongs to the account that gave it — and
    /// §2.22.5 is absolute: the demo "writes to none of the homes a real session uses … there is
    /// nothing on disk to clean up."
    func testTheConnectorScreenChangesNothingOnDiskInTheDemo() async {
        let store = LocalStore()
        let before = store.load(ConnectorSettings.self, ConnectorService.storeKey)

        let model = AppModel()
        model.enterDemo()
        let settings = model.connector.settings

        model.toast = nil
        model.connector.setPreset(settings.preset == .mine ? .graph : .mine)
        XCTAssertEqual(model.toast?.text, DemoCopy.noWrite, "the preset tab did not name the boundary")
        model.toast = nil
        model.connector.setPort(settings.port + 1)
        XCTAssertEqual(model.toast?.text, DemoCopy.noWrite, "the port field did not name the boundary")
        model.toast = nil
        model.connector.setCustom(["tgs_demo_crate"])
        XCTAssertEqual(model.toast?.text, DemoCopy.noWrite, "the custom source list did not name the boundary")
        model.toast = nil
        await model.connector.setEnabled(!settings.enabled)
        XCTAssertEqual(model.toast?.text, DemoCopy.noWrite, "the bridge toggle did not name the boundary")

        XCTAssertEqual(model.connector.settings, settings, "the demo changed a real session's grant")
        XCTAssertEqual(store.load(ConnectorSettings.self, ConnectorService.storeKey), before,
                       "the demo wrote to connector.json")
    }
#endif

    func testEnteringTwiceIsOneDemo() {
        let model = enteredDemo()
        let first = model.demo
        model.enterDemo()
        XCTAssertTrue(model.demo === first)
    }

    // MARK: Reads answered by the world, not by a repository

    func testProfileFeedAndSearchAllAnswerFromTheFixtures() async {
        let model = enteredDemo()
        let profile = await model.loadProfile(username: "tgs_demo_wren", force: true)
        XCTAssertEqual(profile?.node.displayName, "Wren Alderiss")
        XCTAssertEqual(profile?.feeds.map(\.username), ["demo_tidewright", "demo_wren_bench"])
        XCTAssertEqual(profile?.follows.count, 4)

        let channel = await model.loadChannel(username: "demo_tidewright", loaded: 0, cursor: 0, reset: true)
        XCTAssertEqual(channel?.feed.title, "Tidewright")
        XCTAssertEqual(channel?.posts.count, 2)
        XCTAssertTrue(channel?.exhausted ?? false)

        let found = await model.lookupNode("@tgs_demo_juno")
        XCTAssertEqual(found?.username, "tgs_demo_juno")
        let missed = await model.lookupNode("someone_else")
        XCTAssertNil(missed, "and anything else toasts `\(DemoCopy.notANode)`")
    }

    func testTheDemoSheetSaysTelegramIsNotConnected() {
        let model = enteredDemo()
        XCTAssertEqual(model.telegramLabel, DemoCopy.telegramRow)
        XCTAssertEqual(model.feedLabel, "6 sources \u{00B7} 15 posts")
        XCTAssertEqual(model.demo?.networkRow, "4 direct \u{00B7} 7 at +1")
        XCTAssertEqual(model.demo?.nodeCount, 15)
    }
}

// MARK: - §2.22.4's build-time check

final class DemoIsolationTests: XCTestCase {

    /// "`DemoRepo` imports nothing from the TDLib layer, and that is the build-time check … It is a
    /// grep, it runs in the build, and it fails the build."
    ///
    /// The demo's sources are the substituted object. If a TDLib import ever appears in one of them
    /// the substitution has a hole, and the honest place to find that out is here rather than from a
    /// reviewer's proxy log.
    func testNoDemoSourceImportsTDLib() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // Tests/
            .deletingLastPathComponent()          // ios/
            .appendingPathComponent("Sources/Demo", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 4, "the demo's sources are not where this test looks")
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            // Comments are stripped first: these files argue *about* TDLib at length, and a grep
            // that cannot tell the argument from the code would fail on its own documentation.
            let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") }
            for line in code where line.hasPrefix("import ") {
                XCTAssertFalse(line.contains("TDLibKit"),
                               "\(file.lastPathComponent) imports TDLib: \(line)")
            }
            let joined = code.joined(separator: "\n")
            for symbol in ["TDLibKit", "TDLibClient", "TDClient", "downloadFile", "td.api"] {
                XCTAssertFalse(joined.contains(symbol),
                               "\(file.lastPathComponent) names \(symbol); the demo has no route to Telegram")
            }
        }
    }
}
