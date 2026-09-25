// Screens — Status sheet (PRODUCT.md §2.10): opened by tapping the status pill. Live rows for
// connection, account, node, feed, in-flight operations, the last error, and the TDLib version.
// Updates live while open; Refresh Now re-runs the feed refresh and re-reads my card.

import SwiftUI

struct StatusSheetModal: View {
    @Environment(AppModel.self) private var model
    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Status")
            // PRODUCT §2.10, Bluesky only: `Connection`, `Node` and `TDLib` each describe a TDLib
            // client that is not running (PROTOCOL §12.11), so they are absent, not `Unknown`.
            let telegram = model.session.kind != .blueskyOnly
            if telegram { row("Connection", model.connectionLabel) }
            row("Telegram", model.telegramLabel)
            if telegram { row("Node", model.nodeLabel) }
            row("Feed", model.feedLabel)
            row("Pending", model.pendingLabel)
            let bluesky = model.blueskyStatusLabel
            row("Last error", model.lastErrorLabel, isLast: !telegram && bluesky == nil)
            if telegram { row("TDLib", model.tdlibVersion.isEmpty ? "Unknown" : model.tdlibVersion, isLast: bluesky == nil) }
            // PRODUCT §2.35: present with any Bluesky source, absent for everyone else.
            if let bluesky { row("Bluesky", bluesky, isLast: true) }
            HPButton("Refresh Now", style: .accent, enabled: !refreshing) {
                guard !refreshing else { return }
                refreshing = true
                Task {
                    await model.refreshNow()
                    refreshing = false
                }
            }
            .padding(.top, HPTokens.Space.rowPad)
            HPButton("Close", style: .ghost) { model.modal = nil }
                .padding(.top, HPTokens.Space.rowGap)
        }
    }

    private func row(_ label: String, _ value: String, isLast: Bool = false) -> some View {
        HPListItem(isLast: isLast) {
            HPBody(label)
        } trailing: {
            HPMono(value, small: true)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel("\(label): \(value)")
        }
    }
}
