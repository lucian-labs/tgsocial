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
            row("Connection", model.connectionLabel)
            row("Telegram", model.telegramLabel)
            row("Node", model.nodeLabel)
            row("Feed", model.feedLabel)
            row("Pending", model.pendingLabel)
            row("Last error", model.lastErrorLabel)
            row("TDLib", model.tdlibVersion.isEmpty ? "Unknown" : model.tdlibVersion, isLast: true)
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
