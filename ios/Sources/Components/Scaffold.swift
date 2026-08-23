// Components — screen scaffolding: topbar variants, status pill, scrolling column, back button.

import SwiftUI

struct StatusPill: View {
    let status: StatusKind
    var body: some View {
        HPPill(status.label, tone: status == .synced ? .gold : .neutral)
            .accessibilityLabel("Status: \(status.label)")
    }
}

struct BackButton: View {
    let action: () -> Void
    var body: some View {
        HPButton("\u{2039} Back", style: .ghost, size: .small, action: action)
            .accessibilityLabel("Back")
    }
}

/// Topbar + scrolling single column. `leadingBack` swaps the wordmark for `‹ Back`.
struct Screen<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let back: Bool
    let refresh: (() async -> Void)?
    let content: Content

    init(back: Bool = false, refresh: (() async -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.back = back; self.refresh = refresh; self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HPTopbar {
                if back { BackButton { dismiss() } } else { HPWordmark("tgsocial", topbar: true) }
            } trailing: {
                StatusPill(status: model.status)
            }
            scroll
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    @ViewBuilder private var scroll: some View {
        let body = ScrollView(.vertical, showsIndicators: false) {
            HPColumn {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.top, HPTokens.Space.topbarBottom)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        if let refresh {
            body.refreshable { await refresh() }
        } else {
            body
        }
    }
}

/// Muted centred row used for `Loading…` / `That's everything.`
struct FeedFooter: View {
    let text: String
    var body: some View {
        HPMuted(text)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.vertical, HPTokens.Space.rowPad)
    }
}
