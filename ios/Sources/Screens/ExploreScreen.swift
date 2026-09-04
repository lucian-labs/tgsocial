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
            if let node = await model.discovery.lookup(query) {
                query = ""
                model.path.append(.profile(username: node.username))
            } else {
                model.showToast("Not a tgsocial node.", tone: .bad)
            }
            searching = false
        }
    }
}
