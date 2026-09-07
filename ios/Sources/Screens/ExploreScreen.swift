// Screens — Explore (PRODUCT.md §2.4): find a node, Nearby (+1), Directory.

import SwiftUI

struct ExploreScreen: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var searching = false

    var body: some View {
        @Bindable var model = model
        Screen(refresh: { await model.refreshDiscovery(force: true) }) {
            HPTextField(nil, text: $query, placeholder: "Find a node", kind: .text) { submit() }

            // §2.18: a blocked node is not in Explore's rows.
            let nearby = model.visibleNearby
            let directory = model.visibleDirectory

            // PRODUCT §2.24: a query that is not a username also matches `work.does` across every
            // card this client has read.
            if query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
                let matches = model.capabilityMatches(query)
                HPSectionMark("What they do")
                // Permanent, not an empty state. It is the honest description of PROTOCOL §10.7 —
                // `searchPublicChats` indexes usernames and titles, never card contents — and it is
                // on the screen rather than in a footnote, because a search box that stays quiet
                // about its reach is a search box that lies about it.
                HPSmall("Searches the cards you can reach \u{2014} your network and the directory. There is no global search.",
                        color: HPTokens.Colors.faint)
                    .padding(.bottom, HPTokens.Space.rowGap)
                if matches.isEmpty {
                    HPCard { HPMuted("Nobody you can reach lists that.") }
                } else {
                    HPListCard {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { i, entry in
                            // §2.24 draws the row as `@tgs_ana · live sound · Followed by 3 of
                            // yours`: the matched capability is the middle term, and without it
                            // this section is `NEARBY` under a different heading.
                            NodeRow(node: entry.node, followedBy: entry.followedByCount,
                                    subline: "@\(entry.node.username) \u{00B7} \(entry.hits.joined(separator: ", "))",
                                    isLast: i == matches.count - 1) {
                                model.path.append(.profile(username: entry.node.username))
                            }
                        }
                    }
                }
            }

            // PRODUCT §2.31: the requests I have out, above NEARBY; absent when there are none.
            if !model.isDemo { WaitingSection() }

            HPSectionMark("Nearby")
            if nearby.isEmpty {
                HPCard { HPMuted(model.exploreLoading ? "Loading\u{2026}" : "Follow someone and their people appear here.") }
            } else {
                HPListCard {
                    ForEach(Array(nearby.enumerated()), id: \.element.id) { i, entry in
                        NodeRow(node: entry.node, followedBy: entry.followedByCount, isLast: i == nearby.count - 1) {
                            model.path.append(.profile(username: entry.node.username))
                        }
                    }
                }
            }

            HPSectionMark("Directory")
            if directory.isEmpty {
                HPCard { HPMuted(model.exploreLoading ? "Loading\u{2026}" : "No nodes found. Be the first: make yours public.") }
            } else {
                HPListCard {
                    ForEach(Array(directory.enumerated()), id: \.element.id) { i, entry in
                        NodeRow(node: entry.node, isLast: i == directory.count - 1) {
                            model.path.append(.profile(username: entry.node.username))
                        }
                    }
                }
            }
        }
        .task {
            if model.nearby.isEmpty, model.directory.isEmpty, !model.exploreLoading { await model.refreshDiscovery() }
        }
    }

    private func submit() {
        guard !searching, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        Task {
            // PRODUCT §2.31: the field takes an invite link as well as a username.
            if InviteLink.normalise(query) != nil {
                if await model.openInvite(query) { query = "" }
                searching = false
                return
            }
            if let node = await model.lookupNode(query) {
                query = ""
                model.path.append(.profile(username: node.username))
            } else {
                model.showToast(DemoCopy.notANode, tone: .bad)
            }
            searching = false
        }
    }
}
