// Components — screen scaffolding: topbar variants, status pill, scrolling column, back button.

import SwiftUI

/// The status pill is a button: tapping it opens the Status sheet (PRODUCT §1, §2.10).
///
/// In the demo it reads `Demo` and opens the demo sheet instead (§2.22.5). Neutral either way for
/// everything but `Synced`, and never gold here — gold on this pill means a live Telegram
/// connection, and the demo does not have one.
struct StatusPill: View {
    @Environment(AppModel.self) private var model
    let status: StatusKind

    private var opensDemoSheet: Bool { status == .demo }

    var body: some View {
        Button { model.modal = opensDemoSheet ? .demo : .status } label: {
            HPPill(status.label, tone: status == .synced ? .gold : .neutral)
                .hpTouchTarget()
        }
        .buttonStyle(HPPressStyle())
        .accessibilityLabel(opensDemoSheet
            ? "Demo. Opens the demo sheet."
            : "Status: \(status.label). Opens the status sheet.")
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
///
/// `sticky` is a control that rides under the topbar instead of scrolling with the content —
/// Feed's All / Work mode is the only one (PRODUCT §2.24), and it is sticky because a mode you
/// have to scroll back up to leave is a mode you are stuck in. Every other screen passes nothing
/// and gets exactly the layout it had.
struct Screen<Content: View, Sticky: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let back: Bool
    let refresh: (() async -> Void)?
    let sticky: Sticky
    let content: Content

    init(back: Bool = false, refresh: (() async -> Void)? = nil,
         @ViewBuilder sticky: () -> Sticky, @ViewBuilder content: () -> Content) {
        self.back = back; self.refresh = refresh; self.sticky = sticky(); self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HPTopbar {
                if back { BackButton { dismiss() } } else { HPWordmark("tgsocial", topbar: true) }
            } trailing: {
                StatusPill(status: model.status)
            }
            // §2.22, indicator 2: sticky with the topbar, on every screen that has one.
            if model.isDemo { DemoStrip() }
            sticky
                .padding(.horizontal, HPTokens.Space.columnSide)
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

extension Screen where Sticky == EmptyView {
    init(back: Bool = false, refresh: (() async -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.init(back: back, refresh: refresh, sticky: { EmptyView() }, content: content)
    }
}
