// Unit tests — PROTOCOL.md §10, the work extension.
//
// Two halves. The vector loops run the shared `work` section of `docs/card-vectors.json`, so iOS,
// Android and web are held to the same bytes. The behavioural tests below them assert the three
// things a vector cannot: that a §2-only rewrite really does destroy the work lines and a
// round-tripping one really does not (§10.6), that one comments channel carrying both formats
// hands no message to both parsers (§10.4), and that the caps §10.2 names are the caps that hold.
//
// Each behavioural test fails if the feature is removed rather than passing over its absence.

import Foundation
import XCTest
@testable import tgsocial

final class WorkVectorTests: XCTestCase {
    struct Vectors: Decodable {
        struct OpenJSON: Decodable { let intent: String; let until: String }
        struct WorkJSON: Decodable {
            let role: String?
            let does: [String]
            let open: OpenJSON?
            let feeds: [String]
        }
        struct CardJSON: Decodable {
            let name: String?
            let bio: String?
            let link: String?
            let `public`: Bool
            let feeds: [String]
            let follows: [String]
            let replies: String?
        }
        struct ParseCase: Decodable { let name: String; let text: String; let expect: WorkJSON? }
        struct SerialiseCase: Decodable { let name: String; let card: CardJSON; let work: WorkJSON?; let expect: String }
        struct TagCase: Decodable { let `in`: String; let out: String? }
        struct OpenCase: Decodable { let open: OpenJSON?; let today: String; let out: Bool }
        struct VouchOut: Decodable { let node: String; let does: String; let body: String }
        struct VouchParseCase: Decodable { let `in`: String; let out: VouchOut? }
        struct VouchSerialiseCase: Decodable { let node: String; let does: String; let body: String; let out: String }
        struct VouchSelfCase: Decodable { let `in`: String; let voucherNode: String; let out: Bool }
        struct Cases<T: Decodable>: Decodable { let cases: [T] }
        struct Vouch: Decodable {
            let parse: [VouchParseCase]
            let serialise: [VouchSerialiseCase]
            let selfCases: Cases<VouchSelfCase>
            enum CodingKeys: String, CodingKey { case parse, serialise, selfCases = "self" }
        }
        struct Work: Decodable {
            let parse: [ParseCase]
            let serialise: [SerialiseCase]
            let tag: Cases<TagCase>
            let open: Cases<OpenCase>
            let vouch: Vouch
        }
        let work: Work
    }

    private func loadVectors() throws -> Vectors.Work {
        let bundle = Bundle(for: WorkVectorTests.self)
        guard let url = bundle.url(forResource: "card-vectors", withExtension: "json") else {
            XCTFail("card-vectors.json missing from the test bundle"); throw NSError(domain: "tgsocialTests", code: 1)
        }
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url)).work
    }

    private func work(_ json: Vectors.WorkJSON) throws -> Work {
        var out = Work(role: json.role, does: json.does, feeds: json.feeds)
        if let open = json.open {
            out.open = WorkOpen(intent: try XCTUnwrap(WorkIntent(rawValue: open.intent)), until: open.until)
        }
        return out
    }

    func testWorkParseVectors() throws {
        let v = try loadVectors()
        XCTAssertGreaterThan(v.parse.count, 0)
        for c in v.parse {
            let got = WorkCodec.parse(c.text)
            guard let expected = c.expect else {
                XCTAssertNil(got, c.name)
                continue
            }
            guard let got else { XCTFail("\(c.name): expected a work card, got nil"); continue }
            XCTAssertEqual(got.role, expected.role, c.name)
            XCTAssertEqual(got.does, expected.does, c.name)
            XCTAssertEqual(got.open?.intent.rawValue, expected.open?.intent, c.name)
            XCTAssertEqual(got.open?.until, expected.open?.until, c.name)
            XCTAssertEqual(got.feeds, expected.feeds, c.name)
        }
    }

    func testWorkSerialiseVectors() throws {
        let v = try loadVectors()
        for c in v.serialise {
            let card = Card(name: c.card.name, bio: c.card.bio, link: c.card.link, isPublic: c.card.public,
                            feeds: c.card.feeds, follows: c.card.follows, replies: c.card.replies)
            let work = try c.work.map { try self.work($0) }
            XCTAssertEqual(CardCodec.serialise(card, work: work), c.expect, c.name)
            // Round trip: what the serialiser wrote is what the second pass reads back.
            let reparsed = WorkCodec.parse(c.expect)
            XCTAssertEqual(reparsed?.does ?? [], work?.does ?? [], c.name)
            XCTAssertEqual(reparsed?.open?.until, work?.open?.until, c.name)
        }
    }

    func testWorkTagVectors() throws {
        let v = try loadVectors()
        for c in v.tag.cases {
            XCTAssertEqual(WorkCodec.tag(c.in), c.out, "tag(\(c.in))")
        }
    }

    func testWorkOpenVectors() throws {
        let v = try loadVectors()
        for c in v.open.cases {
            let open = try c.open.map { WorkOpen(intent: try XCTUnwrap(WorkIntent(rawValue: $0.intent)), until: $0.until) }
            XCTAssertEqual(WorkCodec.isCurrent(open, today: c.today), c.out,
                           "\(open?.until ?? "nil") on \(c.today)")
        }
    }

    func testVouchParseVectors() throws {
        let v = try loadVectors()
        XCTAssertGreaterThan(v.vouch.parse.count, 0)
        for c in v.vouch.parse {
            let got = VouchCodec.parse(c.in)
            guard let expected = c.out else { XCTAssertNil(got, c.in); continue }
            XCTAssertEqual(got?.node, expected.node, c.in)
            XCTAssertEqual(got?.does, expected.does, c.in)
            XCTAssertEqual(got?.body, expected.body, c.in)
        }
    }

    func testVouchSerialiseVectors() throws {
        let v = try loadVectors()
        for c in v.vouch.serialise {
            XCTAssertEqual(VouchCodec.serialise(node: c.node, does: c.does, body: c.body), c.out, c.node)
            let parsed = VouchCodec.parse(c.out)
            XCTAssertEqual(parsed?.does, WorkCodec.tag(c.does), c.node)
        }
    }

    func testVouchSelfVectors() throws {
        let v = try loadVectors()
        for c in v.vouch.selfCases.cases {
            XCTAssertEqual(VouchCodec.keeps(VouchCodec.parse(c.in), voucherNode: c.voucherNode), c.out,
                           "keeps(\(c.voucherNode))")
        }
    }
}

/// The three things the vectors cannot assert, each written so it fails if §10 is removed.
final class WorkBehaviourTests: XCTestCase {

    /// PROTOCOL §10.6, both halves. §2 says unknown keys are ignored, and ignoring is exactly what
    /// destroys them on the next write — so the hazard is asserted rather than described: a §2-only
    /// rewrite DOES drop the work lines, and a round-tripping one keeps them while changing nothing
    /// a §2 client can see.
    func testWritingBackIsWhatKeepsAWorkCardAlive() throws {
        let text = """
        tgsocial v1
        name: Wren Alderiss
        bio: Tide clocks and bad solder.
        public: yes
        feeds: @demo_tidewright @demo_wren_bench
        follows: @tgs_demo_mox
        replies: @demo_wren_r
        work.role: Tide clocks, built one at a time
        work.does: electronics, tide clocks, bad solder
        work.open: contract until 2026-12-01
        work.feeds: @demo_wren_bench
        """
        let card = try XCTUnwrap(CardCodec.parse(text).card)
        let work = try XCTUnwrap(WorkCodec.parse(text))

        // A v1 client that has never heard of `work.` rewrites the card and the lines are gone.
        // It is behaving correctly, and this is the loss §10.6 bounds.
        let v1Rewrite = CardCodec.serialise(card)
        XCTAssertFalse(v1Rewrite.contains("work."))
        XCTAssertNil(WorkCodec.parse(v1Rewrite))

        // A client that implements §10 writes back what it read: byte-identical, work lines intact.
        let rewrite = CardCodec.serialise(card, work: work)
        XCTAssertEqual(rewrite, text)
        XCTAssertEqual(WorkCodec.parse(rewrite), work)

        // And it changed nothing a §2 client can see — the additive half of the same rule.
        XCTAssertEqual(CardCodec.parse(rewrite).card, card)

        // The write that actually causes this in the app is a FOLLOW, which rewrites the whole
        // pinned message. Both serialisers agree on the §2 half and disagree on nothing else.
        let followed = card.following("tgs_demo_juno")
        XCTAssertNil(WorkCodec.parse(CardCodec.serialise(followed)))
        let kept = try XCTUnwrap(WorkCodec.parse(CardCodec.serialise(followed, work: work)))
        XCTAssertEqual(kept, work)
        XCTAssertTrue(CardCodec.parse(CardCodec.serialise(followed, work: work)).card?.follows("tgs_demo_juno") ?? false)
    }

    /// PROTOCOL §10.4: one channel, two formats, and no message claimed by both. This is what let
    /// §10 reuse §6.1's channel instead of inventing one — and it holds only because a `re:` line
    /// always carries a message id and a `vouch:` line never does.
    func testOneChannelCarriesBothFormatsAndNeitherParserClaimsTheOther() {
        let comment = "re: https://t.me/demo_tidewright/144\nSix inches is the whole reason I stopped trusting that gauge."
        let vouch = "vouch: https://t.me/tgs_demo_wren\ndoes: tide clocks\nBuilt the clock in my studio. Still right."
        let plain = "Just a channel post."
        // A vouch link with a message id is a comment target, not a node — so it is not a vouch.
        let vouchAtAPost = "vouch: https://t.me/demo_tidewright/144\ndoes: tide clocks\nbody"
        // And a `vouch:` with no `does:` is not one either: the claim is specific or it is nothing.
        let bareVouch = "vouch: https://t.me/tgs_demo_wren\nGreat person."

        XCTAssertNotNil(CommentCodec.parse(comment))
        XCTAssertNil(VouchCodec.parse(comment))

        XCTAssertNotNil(VouchCodec.parse(vouch))
        XCTAssertNil(CommentCodec.parse(vouch))

        for message in [plain, vouchAtAPost, bareVouch] {
            XCTAssertNil(CommentCodec.parse(message), message)
            XCTAssertNil(VouchCodec.parse(message), message)
        }
    }

    /// PROTOCOL §10.2: the caps are caps, malformed values are dropped rather than fatal, and a
    /// full work card costs a small fraction of the one Telegram message a card is.
    func testTheCapsHoldAndAFullWorkCardIsCheap() throws {
        let longRole = String(repeating: "a", count: 200)
        let tags = (1...20).map { "tag number \($0)" }.joined(separator: ", ")
        let text = """
        tgsocial v1
        name: Bob
        public: yes
        feeds: @bob_notes
        work.role: \(longRole)
        work.does: \(tags), live/sound, x
        work.open: freelancing until 2026-12-01
        """
        let work = try XCTUnwrap(WorkCodec.parse(text))
        XCTAssertEqual(work.role?.count, WorkCodec.roleMax)
        XCTAssertEqual(work.does.count, WorkCodec.doesMax)
        // An intent outside the closed set, a tag outside the grammar and a tag too short are all
        // dropped, and none of them took the card down with them.
        XCTAssertNil(work.open)
        XCTAssertFalse(work.does.contains("live/sound"))
        XCTAssertFalse(work.does.contains("x"))
        XCTAssertNotNil(CardCodec.parse(text).card, "a malformed work line never invalidates the card")

        // A card whose every work line is malformed has no work card at all.
        XCTAssertNil(WorkCodec.parse("tgsocial v1\nname: Bob\nwork.does: ,,\nwork.open: someday\nwork.feeds: @not_listed"))

        // The cost, in the units §10.2 measures: one Telegram message of 4096 characters. A filled-in
        // work card — §10.2's own example — costs about what a `bio` costs.
        let filled = Work(role: "Staff product architect at Lucian Labs",
                          does: ["swift", "product architecture", "live sound"],
                          open: WorkOpen(intent: .contract, until: "2026-12-01"),
                          feeds: ["waveloop_devlog"])
        XCTAssertLessThan(WorkCodec.lines(filled).joined(separator: "\n").count, 200)

        // Even at every cap at once — 80-character role, twelve 24-character tags — the extension
        // takes an eighth of the message, so §2's 4096 cap is unmoved in practice as well as on
        // paper: a card is only ever full because of `follows:`.
        let maxed = Work(role: String(repeating: "r", count: WorkCodec.roleMax),
                         does: (1...WorkCodec.doesMax).map { String(("capability tag \($0) padded").prefix(WorkCodec.tagMax)) },
                         open: WorkOpen(intent: .contract, until: "2026-12-01"),
                         feeds: ["a_work_feed"])
        XCTAssertEqual(maxed.does.count, WorkCodec.doesMax)
        XCTAssertLessThan(WorkCodec.lines(maxed).joined(separator: "\n").count, CardCodec.maxLength / 8)
        XCTAssertFalse(CardCodec.isFull(Card(name: "Bob", feeds: ["a_work_feed"]), work: maxed))
    }

    /// §10.3's two rules, and the second is the one that makes the first mean anything: an expiry
    /// nobody ever has to renew is no expiry at all.
    func testAnExpiryNobodyHasToRenewIsNotAnExpiry() {
        let today = "2026-09-06"
        XCTAssertTrue(WorkCodec.isCurrent(WorkOpen(intent: .work, until: today), today: today))
        XCTAssertFalse(WorkCodec.isCurrent(WorkOpen(intent: .work, until: "2026-09-05"), today: today))
        // Exactly 180 days out is current; 181 is not.
        let edge = try? XCTUnwrap(WorkCodec.day(after: WorkCodec.openHorizonDays, from: today))
        let past = try? XCTUnwrap(WorkCodec.day(after: WorkCodec.openHorizonDays + 1, from: today))
        XCTAssertTrue(WorkCodec.isCurrent(WorkOpen(intent: .hiring, until: edge ?? ""), today: today))
        XCTAssertFalse(WorkCodec.isCurrent(WorkOpen(intent: .hiring, until: past ?? ""), today: today))
        XCTAssertFalse(WorkCodec.isCurrent(WorkOpen(intent: .work, until: "2099-01-01"), today: today))
        // The writer's three horizons are all well inside the cap, so nothing the app offers is
        // born already invisible.
        for horizon in WorkCodec.openHorizons {
            let until = WorkCodec.day(after: horizon, from: today) ?? ""
            XCTAssertTrue(WorkCodec.isCurrent(WorkOpen(intent: .contract, until: until), today: today), "\(horizon)")
        }
    }

    /// The date arithmetic is UTC integer arithmetic on the proleptic Gregorian calendar, so a
    /// reader's time zone cannot move an expiry and February cannot gain a day.
    func testCalendarDaysAreRealDays() {
        XCTAssertTrue(WorkCodec.isCalendarDay("2024-02-29"))
        XCTAssertFalse(WorkCodec.isCalendarDay("2026-02-29"))
        XCTAssertFalse(WorkCodec.isCalendarDay("2026-02-30"))
        XCTAssertFalse(WorkCodec.isCalendarDay("2026-13-01"))
        XCTAssertFalse(WorkCodec.isCalendarDay("2026-1-01"))
        XCTAssertEqual(WorkCodec.daysBetween("2026-02-28", "2026-03-01"), 1)
        XCTAssertEqual(WorkCodec.daysBetween("2024-02-28", "2024-03-01"), 2)
        XCTAssertEqual(WorkCodec.daysBetween("2026-12-01", "2026-11-30"), -1)
        XCTAssertEqual(WorkCodec.day(after: 30, from: "2026-12-01"), "2026-12-31")
        XCTAssertEqual(WorkCodec.day(after: 90, from: "2026-12-01"), "2027-03-01")
    }

    /// PRODUCT §2.23: the `FOR` control offers the horizon that still covers the card's own date.
    /// The card carries the end date and not the horizon, so this rounding is the only thing
    /// standing between "I changed my bio" and "my `work.open` now ends in 30 days" — the one value
    /// §10.3 makes every reader enforce.
    func testAHorizonCoversTheDateTheCardAlreadyCarries() {
        for offered in WorkCodec.openHorizons {
            XCTAssertEqual(WorkCodec.horizon(remainingDays: offered), offered, "\(offered) days left")
        }
        // Part-way through a horizon it rounds UP to the tab that still covers the date, so a
        // re-save keeps roughly the end date rather than shortening it.
        XCTAssertEqual(WorkCodec.horizon(remainingDays: 1), 30)
        XCTAssertEqual(WorkCodec.horizon(remainingDays: 31), 60)
        XCTAssertEqual(WorkCodec.horizon(remainingDays: 89), 90)
        // A card written with a longer horizon than this client offers clamps to the longest tab,
        // and an already-expired one lands on the shortest — both of which the writer can see
        // before they save.
        XCTAssertEqual(WorkCodec.horizon(remainingDays: WorkCodec.openHorizonDays), 90)
        XCTAssertEqual(WorkCodec.horizon(remainingDays: -400), 30)
    }

    /// PRODUCT §2.23 / §2.25 date formats. `until 1 Dec` drops the year only when it is this one,
    /// and a vouch's date is a month and a year — the one place in the app time is not relative.
    func testWorkDatesReadTheWayTheSpecWritesThem() {
        let now = Date(timeIntervalSince1970: 1_788_700_000) // 2026-09-06 UTC
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(WorkDate.short("2026-12-01", now: now, calendar: utc), "1 Dec")
        XCTAssertEqual(WorkDate.short("2027-03-05", now: now, calendar: utc), "5 Mar 2027")
        XCTAssertEqual(WorkDate.full("2026-12-05"), "5 Dec 2026")
        XCTAssertEqual(WorkDate.monthYear(unix: 1_772_000_000, calendar: utc), "Feb 2026")
    }
}

/// PRODUCT §2.26 — work in the demo. A reviewer who never signs in has to reach every branch of
/// §2.23–§2.25, and the fifth vouch fixture is a self-vouch that must not render anywhere: it is in
/// the table precisely so a client which forgot PROTOCOL §10.4 fails visibly on all three platforms.
@MainActor
final class DemoWorkTests: XCTestCase {

    func testSixNodesCarryWorkAndTheReaderCarriesNone() {
        let world = DemoWorld()
        let withWork = world.nodes.values.filter { $0.work != nil }
        XCTAssertEqual(withWork.count, 6)
        XCTAssertNil(world.myWork, "the first thing the demo shows about work is the empty state on your own card")
        XCTAssertNil(world.node(DemoFixtures.reader)?.work)
    }

    /// Every fixture work card goes through `WorkCodec`, so `work.feeds` is intersected with the
    /// node's own `feeds:` exactly as a card read off Telegram would be.
    func testFixtureWorkFeedsAreAlwaysChannelsTheNodeAlreadyClaims() {
        let world = DemoWorld()
        for (_, info) in world.nodes {
            guard let work = info.work, let card = info.card else { continue }
            for feed in work.feeds {
                XCTAssertTrue(card.lists(feed: feed), "@\(info.username) marks @\(feed) as work without claiming it")
            }
        }
    }

    /// §2.24: ordered by end date ascending — soonest first. §2.26 writes the resulting order down
    /// because three platforms otherwise produce three, and the demo would not be one demo.
    func testOpenNowPaintsHaskJunoWrenPell() {
        let world = DemoWorld()
        let today = WorkCodec.today(world.startedAt)
        let open = world.nodes.values
            .compactMap { info -> (String, String)? in
                guard let open = info.work?.open, WorkCodec.isCurrent(open, today: today) else { return nil }
                return (info.username, open.until)
            }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : Username.key($0.0) < Username.key($1.0) }
        XCTAssertEqual(open.map(\.0),
                       ["tgs_demo_hask", "tgs_demo_juno", "tgs_demo_wren", "tgs_demo_pell"])
    }

    /// The dates are `+N d` from the moment the demo is ENTERED. A literal date in a fixture file
    /// rots into an expired intent and then `OPEN NOW` is permanently empty, which is a fixture
    /// that tests nothing.
    func testIntentDatesAreDerivedAtEntryAndNeverExpired() {
        let world = DemoWorld(now: Date(timeIntervalSince1970: 4_000_000_000))
        let today = WorkCodec.today(world.startedAt)
        let opens = world.nodes.values.compactMap { $0.work?.open }
        XCTAssertEqual(opens.count, 4)
        for open in opens {
            XCTAssertTrue(WorkCodec.isCurrent(open, today: today), "\(open.until) has rotted")
        }
    }

    /// §10.4, as a fixture rather than as an assertion in a client: Wren's own comments channel
    /// carries a vouch for Wren, and it must not be in the index any screen reads.
    func testTheSelfVouchFixtureIsAbsentFromTheIndex() {
        let world = DemoWorld()
        XCTAssertEqual(DemoFixtures.vouches.filter { $0.voucher == $0.about }.count, 1,
                       "the self-vouch fixture is the point of the table; do not remove it")
        let all = world.vouchIndex.values.flatMap { $0 }
        XCTAssertEqual(all.count, DemoFixtures.vouches.count - 1)
        XCTAssertFalse(all.contains { Username.key($0.node) == Username.key($0.ownerUsername) })
        XCTAssertFalse(CommentRepository.vouches(for: "tgs_demo_wren", in: world.vouchIndex)
            .contains { Username.key($0.ownerUsername) == "tgs_demo_wren" })
    }

    /// The three tag states one screen each: claimed and vouched, claimed with none, and vouched
    /// but not claimed (`kiln repair`, which Juno does not claim).
    func testJunoShowsAClaimedTagAVouchedTagAndOneNobodyClaimed() {
        let world = DemoWorld()
        let juno = world.node("tgs_demo_juno")
        XCTAssertEqual(juno?.work?.does, ["ceramics", "glaze chemistry"])
        let vouches = CommentRepository.vouches(for: "tgs_demo_juno", in: world.vouchIndex)
        XCTAssertEqual(Set(vouches.map(\.does)), ["glaze chemistry", "kiln repair"])
        XCTAssertFalse(juno?.work?.does.contains("kiln repair") ?? true,
                       "`kiln repair` is the VOUCHED, NOT CLAIMED row")
        // Wren carries a claimed tag with no vouch at all, which is the row that must not be a
        // control (§2.23).
        let wrenVouches = CommentRepository.vouches(for: "tgs_demo_wren", in: world.vouchIndex)
        XCTAssertEqual(Set(wrenVouches.map(\.does)), ["tide clocks", "bad solder"])
        XCTAssertTrue(world.node("tgs_demo_wren")?.work?.does.contains("electronics") ?? false)
    }

    /// §2.25 renders newest first, and a vouch's date is a month and a year — so the fixtures have
    /// to span more than one year or the format is never exercised.
    func testVouchesAreNewestFirstAndSpanMoreThanOneYear() {
        let world = DemoWorld()
        let vouches = CommentRepository.vouches(for: "tgs_demo_wren", in: world.vouchIndex)
        XCTAssertEqual(vouches.map(\.date), vouches.map(\.date).sorted(by: >))
        XCTAssertGreaterThan(Set(vouches.map { WorkDate.monthYear(unix: $0.date) }).count, 1)
    }
}

/// PRODUCT §2.24 — the mode, and the one state it must never be.
@MainActor
final class WorkModeTests: XCTestCase {
    private let store = LocalStore()
    private var savedMode: FeedMode?
    private var savedCard: Card?
    private var savedWork: Work?

    /// `feedMode` persists on assignment (PROTOCOL §7), so the suite borrows the real store and
    /// puts back what it found.
    override func setUp() {
        savedMode = store.load(FeedMode.self, LocalStore.feedMode)
        savedCard = store.load(Card.self, LocalStore.myCard)
        savedWork = store.load(Work.self, LocalStore.myWork)
    }

    override func tearDown() {
        store.save(savedMode, LocalStore.feedMode)
        store.save(savedCard, LocalStore.myCard)
        store.save(savedWork, LocalStore.myWork)
    }

    /// §2.24: "the control is visible in both modes, so it is never a state someone is stuck in."
    /// The mode is remembered and the control is conditional, so the two disagree the moment the
    /// last work feed leaves the network — unfollowed, un-marked, or simply not read yet on a cold
    /// launch. Painting the work column then leaves a reader in a column with no way out, so
    /// availability decides what is rendered and the stored preference waits.
    func testAModeWhoseControlIsGoneIsNotTheModeFeedPaints() {
        let model = AppModel()
        model.myCard = Card(name: "Wren", feeds: ["demo_wren_bench"])
        model.myWork = nil
        model.feedMode = .work

        XCTAssertFalse(model.workModeAvailable)
        XCTAssertEqual(model.renderedFeedMode, .all, "the work column has no control above it here")
        XCTAssertEqual(model.feedPosts.count, model.visiblePosts.count,
                       "and the list falls back with the screen, or All mode paints work posts")

        // Mark one of my own feeds as work and the control — and the mode — come back. The
        // preference was kept, not cleared, so the reader lands where they left off.
        model.myWork = Work(feeds: ["demo_wren_bench"])
        XCTAssertTrue(model.workModeAvailable)
        XCTAssertEqual(model.renderedFeedMode, .work)
    }

    /// PRODUCT §2.23: Edit Card opens on the horizon that still covers my own `work.open`, so a
    /// save that touched only the bio does not move the date. A card with no intent opens on the
    /// first tab, which is what the writer is choosing rather than reading.
    func testEditCardOpensOnTheHorizonMyOwnCardAlreadyCarries() throws {
        let model = AppModel()
        XCTAssertEqual(model.editCardHorizon, WorkCodec.openHorizons[0], "no intent, nothing to recover")

        for offered in WorkCodec.openHorizons {
            let until = try XCTUnwrap(WorkCodec.day(after: offered, from: model.workToday))
            model.myWork = Work(open: WorkOpen(intent: .contract, until: until))
            XCTAssertEqual(model.editCardHorizon, offered, "a \(offered)-day intent reopened on another horizon")
        }
    }
}
