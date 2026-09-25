// Unit tests — on-screen copy is labels, not explanation (PRODUCT.md §3, Elijah 2026-09-25:
// "remove all the exposition on the app").
//
// What is measured: every string the exposition pass touched is the spec's verbatim copy, and every
// confirm and helper line is at most ONE sentence — §3's rules 1 and 3. A regression that puts a
// "why" sentence back on screen fails here by sentence count, whatever words it uses.

import Foundation
import XCTest
@testable import tgsocial

@MainActor
final class ExpositionTests: XCTestCase {

    /// Sentences in a line: terminal punctuation followed by a space or the end. `…` and a trailing
    /// colon are not terminators; `e.g.`-style abbreviations do not occur in this copy.
    private func sentences(_ text: String) -> Int {
        let scalars = Array(text.trimmingCharacters(in: .whitespaces))
        var n = 0
        for (i, c) in scalars.enumerated() where c == "." || c == "?" || c == "!" {
            if i == scalars.count - 1 || scalars[i + 1] == " " || scalars[i + 1] == "\n" { n += 1 }
        }
        return max(n, text.isEmpty ? 0 : 1)
    }

    /// §3 rule 3: a confirm states its consequence in one sentence. Each of these is the whole of
    /// the muted text its modal shows.
    func testEveryConfirmIsOneSentence() {
        let confirms: [String: String] = [
            "report": ReportConfirm.paragraph,
            "block (Bluesky)": BlueskyCopy.blockBody,
            "sign out of Bluesky": BlueskyCopy.signOutBody,
            "link": BlueskyCopy.linkBody,
            "unlink": BlueskyCopy.unlinkBody,
            "make private node": MakePrivateNodeModal.consequence,
            "remove member": RemoveMemberModal.body,
            "add private feed": AddPrivateFeedModal.body,
            "invite": PrivateInviteModal.warning,
            "leave private": LeavePrivateModal.body,
            "delete my node": DeleteNodeModal.consequence(username: "tgs_elijah", replies: "tgs_elijah_r", privateClause: nil),
            "delete my node (private)": DeleteNodeModal.consequence(username: "tgs_elijah", replies: "tgs_elijah_r",
                                                                    privateClause: "your private node and 1 private feed"),
        ]
        for (name, text) in confirms {
            XCTAssertEqual(sentences(text), 1, "\(name): \"\(text)\"")
        }
    }

    /// The copy PRODUCT §2 now writes down, verbatim — the spec is the source of truth (§3).
    func testTheTrimmedCopyIsTheSpecs() {
        XCTAssertEqual(ReportConfirm.paragraph, "It's hidden here and emailed to elijah@lucianlabs.ca.")
        XCTAssertEqual(DeleteNodeModal.consequence(username: "tgs_elijah", replies: "tgs_elijah_r", privateClause: nil),
                       "Deletes @tgs_elijah and @tgs_elijah_r and everything in them; your feeds stay.")
        XCTAssertEqual(DeleteNodeModal.cannotUndo, "This can't be undone.")
        XCTAssertEqual(MakePrivateNodeModal.consequence, "People you approve can read everything in it, and so can Telegram.")
        XCTAssertEqual(RemoveMemberModal.body, "They lose access now; what they saved stays with them.")
        XCTAssertEqual(AddPrivateFeedModal.body, "You approve its members separately.")
        XCTAssertEqual(PrivateInviteModal.warning, "Anyone with this link can ask to join.")
        XCTAssertEqual(LeavePrivateModal.body, "Their private posts leave your feed.")
        XCTAssertEqual(AppModel.PrivateCopy.inviteCopied, "Invite copied.")
        XCTAssertEqual(AppModel.PrivateCopy.asked, "Asked.")
        XCTAssertEqual(AppModel.PrivateCopy.youAreIn("Elijah \u{00B7} private"), "You're in Elijah \u{00B7} private.")
        XCTAssertEqual(AppModel.PrivateCopy.privateLinkCopied, "Link copied. Members only.")
        XCTAssertEqual(BlueskyCopy.signOutBody, "Your Bluesky follows leave your feed.")
        XCTAssertEqual(BlueskyCopy.linkBody, "Your followers here see your Bluesky posts.")
        XCTAssertEqual(BlueskyCopy.linked, "Linked.")
        XCTAssertEqual(BlueskyCopy.unlinkBody, "Your Bluesky posts leave your followers' feeds here.")
        XCTAssertEqual(BlueskyCopy.sessionEnded, "Bluesky signed you out.")
        XCTAssertEqual(BlueskyCopy.blockBody, "Their posts disappear here, and they aren't told.")
        XCTAssertEqual(AppModel.cardFullText, "Card is full.\nShorten your bio or drop a tag.")
    }

    /// §2.35's waiting state carries the one helper line on its screen, and it is one sentence.
    func testTheSignInWaitingStateHasOneHelperLine() {
        XCTAssertEqual(BlueskyCopy.finishInBrowser, "Finish in your browser.")
        XCTAssertEqual(sentences(BlueskyCopy.finishInBrowser), 1)
        XCTAssertEqual(BlueskyCopy.waiting, "Waiting for Bluesky\u{2026}")
    }

    #if targetEnvironment(macCatalyst)
    /// §2.14: the Connector's scope line is the live count, nothing else. The Connector (and its
    /// fixture) exists only on Catalyst.
    func testTheConnectorScopeLineIsTheCountAlone() {
        let graph = ScopeResolver.resolve(preset: .graph, inputs: ConnectorFixture.inputs)
        XCTAssertEqual(graph.summary, "\(graph.count) sources")
        XCTAssertFalse(graph.summary.contains("."), "no sentence rides along with the count")
    }
    #endif

    /// A long helper line is how exposition comes back. Every one of the lines kept on screen is
    /// under 70 characters — the longest the spec keeps is the vouch sheet's (§2.25).
    func testKeptHelperLinesAreShort() {
        let kept = [
            BlueskyCopy.finishInBrowser, ReportConfirm.paragraph, BlueskyCopy.blockBody, BlueskyCopy.linkBody,
            MakePrivateNodeModal.consequence, RemoveMemberModal.body, PrivateInviteModal.warning,
            "You can't remove a vouch someone wrote. Report it or block them.",
        ]
        for line in kept { XCTAssertLessThan(line.count, 70, line) }
    }
}
