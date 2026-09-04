// Demo — the two things that are always on screen, and the sheet behind the pill
// (PRODUCT.md §2.22, §2.22.5).

import SwiftUI

/// The strip docked under the topbar (§2.22, indicator 2): full column width, `bg2` fill, hairline
/// `line` below, mono small in `muted`. Sticky with the topbar, on every screen.
///
/// It is not dismissible and has no control on it. A demo a real user can wander into must never be
/// mistakable for the app, and the line that says so cannot be something they can turn off.
struct DemoStrip: View {
    var body: some View {
        HPMonoSmall(DemoCopy.strip, color: HPTokens.Colors.muted)
            .lineLimit(2)
            .frame(maxWidth: HPTokens.Space.columnMax, alignment: .leading)
            .padding(.vertical, HPTokens.Space.rowGap)
            .padding(.horizontal, HPTokens.Space.topbarX)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(HPTokens.Colors.bg2)
            .overlay(alignment: .bottom) {
                Rectangle().fill(HPTokens.Colors.line).frame(height: HPTokens.borderWidth)
            }
            .accessibilityLabel(DemoCopy.strip)
    }
}

/// The same line over the full-screen viewer's dark surface (§2.22: "It persists into the
/// full-screen media viewers and the carousel — the one place the topbar hides"). An unmarked
/// full-screen photo is exactly the screenshot that could be mistaken for someone's real Telegram,
/// so the viewer gets the strip drawn over its own ground rather than losing it.
struct DemoViewerStrip: View {
    var body: some View {
        HPMonoSmall(DemoCopy.strip, color: HPTokens.Colors.charcoalText)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.vertical, HPTokens.Space.rowGap)
            .padding(.horizontal, HPTokens.Space.topbarX)
            .frame(maxWidth: .infinity)
            // No fill of its own: the viewer's ground is already `ink` at `viewerBackdrop`, and a
            // second panel over it would be a surface the kit does not have.
            .accessibilityLabel(DemoCopy.strip)
    }
}

/// The demo sheet (§2.22.5), in the §2.10 status sheet's place. `Telegram · Not connected` is the
/// row that answers the reviewer's question without them having to take our word for §2.22.4.
struct DemoSheetModal: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark(DemoCopy.sheetMark)
            HPH2(DemoCopy.sheetTitle)
            HPMuted(DemoCopy.sheetBody)
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            row("Nodes", "\(model.demo?.nodeCount ?? 0)")
            row("Feeds", model.demo?.feedsRow ?? "")
            row("Network", model.demo?.networkRow ?? "")
            row("Telegram", DemoCopy.telegramRow, isLast: true)
            HPButton(DemoCopy.leaveButton, style: .primary) { model.leaveDemo() }
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
