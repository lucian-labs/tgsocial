// Components — screen scaffolding: topbar variants, status pill, scrolling column, back button.

import SwiftUI

/// The status pill is a button: tapping it opens the Status sheet (PRODUCT §1, §2.10).
struct StatusPill: View {
    @Environment(AppModel.self) private var model
    let status: StatusKind
    var body: some View {
        Button { model.modal = .status } label: {
            HPPill(status.label, tone: status == .synced ? .gold : .neutral)
                .hpTouchTarget()
        }
        .buttonStyle(HPPressStyle())
        .accessibilityLabel("Status: \(status.label). Opens the status sheet.")
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
        // PRODUCT §1: content scrolls under the floating bottom chrome and pads its bottom by the
        // chrome's measured height — the tab bar, plus the now-playing dock and its gap whenever
        // audio is playing (PRODUCT §2.11). HPColumn adds the cardGap above it, so the last card
        // always clears the chrome by exactly one card gap, and by nothing extra once it is gone.
        let body = ScrollView(.vertical, showsIndicators: false) {
            HPColumn(bottomPadded: false) {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.top, HPTokens.Space.topbarBottom)
                    .padding(.bottom, model.bottomChromeHeight)
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
