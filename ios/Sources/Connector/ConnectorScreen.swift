// Screens — Connector (PRODUCT.md §2.14). Mac only: a fifth tab that exists nowhere else,
// because a phone is not a host for a local service an assistant dials.
//
// Every string here is §2.14's. The screen governs the bridge and shows what it did — the two
// things that make a grant like this reviewable rather than merely configured.

#if targetEnvironment(macCatalyst)

import SwiftUI

struct ConnectorScreen: View {
    @Environment(AppModel.self) private var model
    @State private var portText = ""
    @State private var confirm: Confirmation?

    private enum Confirmation: Equatable {
        case rotate
        case grant(WriteGrant)
    }

    /// PRODUCT §2.14: "enabling one shows a one-line confirm … because it is a grant, not a
    /// preference." One case per switch, so the sentence is the switch's own.
    enum WriteGrant: String, Equatable, CaseIterable {
        case post, comment, card

        var row: String {
            switch self {
            case .post: return "Post to my feeds"
            case .comment: return "Comment as me"
            case .card: return "Edit my card"
            }
        }

        var question: String {
            switch self {
            case .post: return "Let an assistant post to your feeds?"
            case .comment: return "Let an assistant comment as you?"
            case .card: return "Let an assistant edit your card?"
            }
        }

        var keyPath: WritableKeyPath<ConnectorWrites, Bool> {
            switch self {
            case .post: return \.post
            case .comment: return \.comment
            case .card: return \.card
            }
        }
    }

    private var connector: ConnectorService { model.connector }

    var body: some View {
        Screen {
            HPSectionMark("Connector")
            HPMuted("Let an assistant read your feeds.")
                .padding(.bottom, HPTokens.Space.cardGap)

            bridgeCard

            HPSectionMark("Scope")
            scopeCard

            HPSectionMark("Writes")
            writesCard

            HPSectionMark("Activity")
            activityCard
            HPButton("Clear Activity", style: .ghost, size: .small) { connector.clearActivity() }
                .padding(.bottom, HPTokens.Space.cardGap)

            HPMuted("Connected assistants read through tgsocial; they never see your Telegram sign-in.")
                .padding(.top, HPTokens.Space.rowPad)
        }
        .onAppear { portText = String(connector.settings.port) }
        .hpModal(isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            switch confirm {
            case .rotate: rotateModal
            case .grant(let grant): grantModal(grant)
            case nil: EmptyView()
            }
        }
    }

    // MARK: Bridge

    @ViewBuilder private var bridgeCard: some View {
        let isOn = connector.status.isOn
        HPListCard {
            HPListItem {
                HPBody("Bridge")
            } trailing: {
                HStack(spacing: HPTokens.Space.rowGap) {
                    HPToggle(isOn: Binding(get: { connector.settings.enabled },
                                           set: { on in Task { await connector.setEnabled(on) } }),
                             label: "Bridge")
                    HPMonoSmall(bridgeState, color: isOn ? HPTokens.Colors.accent : HPTokens.Colors.muted)
                }
            }
            HPListItem {
                HPBody("Port")
            } trailing: {
                // §2.14: editable only while the bridge is off.
                if connector.settings.enabled {
                    HPMono(String(connector.settings.port))
                } else {
                    HPTextField(text: $portText, placeholder: String(ConnectorHandshake.defaultPort), kind: .number) {
                        commitPort()
                    }
                    .frame(maxWidth: HPTokens.Space.menuWidth / 2)
                    .onChange(of: portText) { _, _ in commitPort() }
                }
            }
            HPListItem(isLast: true) {
                HPBody("Token")
            } trailing: {
                HStack(spacing: HPTokens.Space.btnRowGap) {
                    HPMono(maskedToken)
                        .accessibilityLabel("Token, hidden")
                    HPButton("Copy", style: .neutral, size: .small, enabled: !connector.token.isEmpty) {
                        model.copyToken(connector.token)
                    }
                    HPButton("Rotate", style: .ghost, size: .small, enabled: !connector.token.isEmpty) {
                        confirm = .rotate
                    }
                }
            }
        }
        if case .failed(let message) = connector.status {
            HPCard { HPSmall(message, color: HPTokens.Colors.bad) }
        }
    }

    private var bridgeState: String {
        switch connector.status {
        case .off, .failed: return "Off"
        case .starting: return "Starting"
        case .listening(let port): return "On \u{00B7} 127.0.0.1:\(port)"
        }
    }

    private var maskedToken: String {
        connector.token.isEmpty ? "Not set" : String(repeating: "\u{2022}", count: 8)
    }

    private func commitPort() {
        let digits = portText.filter(\.isNumber)
        if digits != portText { portText = digits }
        guard let port = Int(digits), port > 0, port <= 65535 else { return }
        connector.setPort(port)
    }

    // MARK: Scope

    @ViewBuilder private var scopeCard: some View {
        let scope = connector.scope
        HPTabs(items: ScopePreset.allCases,
               selected: Binding(get: { connector.settings.preset },
                                 set: { preset in
                                     connector.setPreset(preset)
                                     // Selecting `Custom` pushes the editable list — on every tap,
                                     // not only on a change, so it stays reachable once selected.
                                     if preset == .custom { model.path.append(.connectorCustom) }
                                 })) { $0.label }
        HPCard {
            HPMuted(scope.summary)
            HPButton("Review Sources", style: .ghost, size: .small) {
                model.path.append(.connectorSources)
            }
            .padding(.top, HPTokens.Space.rowPad)
        }
    }

    // MARK: Writes

    @ViewBuilder private var writesCard: some View {
        HPListCard {
            ForEach(Array(WriteGrant.allCases.enumerated()), id: \.element) { index, grant in
                HPListItem(isLast: index == WriteGrant.allCases.count - 1) {
                    HPBody(grant.row)
                } trailing: {
                    HStack(spacing: HPTokens.Space.rowGap) {
                        HPToggle(isOn: Binding(get: { connector.settings.writes[keyPath: grant.keyPath] },
                                               set: { on in
                                                   // Turning one *off* is not a grant, so it needs no confirm.
                                                   if on { confirm = .grant(grant) }
                                                   else { connector.setWrite(grant.keyPath, false) }
                                               }),
                                 label: grant.row)
                        HPMonoSmall(connector.settings.writes[keyPath: grant.keyPath] ? "On" : "Off")
                    }
                }
            }
        }
        HPMuted("Writes are off until you turn them on. Each one is separate.")
            .padding(.bottom, HPTokens.Space.cardGap)
    }

    // MARK: Activity

    @ViewBuilder private var activityCard: some View {
        let entries = connector.audit.entries
        if entries.isEmpty {
            HPCard { HPMuted("Nothing yet.") }
        } else {
            HPCard {
                VStack(alignment: .leading, spacing: HPTokens.Space.rowGap) {
                    ForEach(entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: HPTokens.Space.rowGap) {
                            HPMonoSmall(ConnectorActivity.time(entry.at), color: HPTokens.Colors.faint)
                            HPMonoSmall(ConnectorActivity.label(entry), color: HPTokens.Colors.ink)
                            Spacer(minLength: HPTokens.Space.rowGap)
                            HPMonoSmall(ConnectorActivity.outcome(entry),
                                        color: entry.outcome.isRefusal || entry.outcome.isFailure
                                            ? HPTokens.Colors.bad : HPTokens.Colors.muted)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: Modals

    @ViewBuilder private var rotateModal: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPH2("Rotate the token?")
            HPMuted("Connected assistants stop working until you give them the new one.")
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            HPButtonRow {
                HPButton("Rotate", style: .accent) {
                    confirm = nil
                    Task { await connector.rotateToken() }
                }
            } b: {
                HPButton("Cancel", style: .ghost) { confirm = nil }
            }
        }
    }

    @ViewBuilder private func grantModal(_ grant: WriteGrant) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HPH2(grant.question)
            HPButtonRow {
                HPButton("Allow", style: .accent) {
                    connector.setWrite(grant.keyPath, true)
                    confirm = nil
                }
            } b: {
                HPButton("Cancel", style: .ghost) { confirm = nil }
            }
            .padding(.top, HPTokens.Space.cardPad)
        }
    }
}

/// The Activity row's three columns (§2.14): time, what was asked, what happened.
enum ConnectorActivity {
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func time(_ date: Date) -> String { clock.string(from: date) }

    /// `Feed`, `Node @tgs_ana`, `Post` — the tool as a person reads it, not as HTTP writes it.
    static func label(_ entry: AuditEntry) -> String {
        let parts = entry.tool.split(separator: " ", maxSplits: 1).map(String.init)
        let path = parts.count == 2 ? parts[1] : entry.tool
        let segments = path.split(separator: "/").map(String.init)
        guard let noun = segments.first else { return path }
        let name = noun.prefix(1).uppercased() + noun.dropFirst()
        guard segments.count > 1 else { return name }
        return name + " @" + segments[1]
    }

    /// `30 posts`, `cached`, `Refused, read-only`.
    static func outcome(_ entry: AuditEntry) -> String {
        switch entry.outcome {
        case .ok:
            return readable(entry.detail)
        case .refused(let why):
            return "Refused, " + why
        case .failed(let why):
            return "Failed, " + why
        }
    }

    /// `posts=30` reads as `30 posts`; a bare verdict like `cached` is already the right words.
    private static func readable(_ detail: String) -> String {
        guard let equals = detail.firstIndex(of: "=") else {
            return detail.isEmpty ? "ok" : detail
        }
        let noun = String(detail[..<equals])
        let value = String(detail[detail.index(after: equals)...])
        guard !value.isEmpty else { return noun }
        return value + " " + noun
    }
}

/// PRODUCT §2.14: "`Review Sources` pushes a plain list of the usernames currently exposed, so
/// the answer to 'what can it see' is always one tap away."
struct ConnectorSourcesScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scope = model.connector.scope
        Screen(back: true) {
            HPSectionMark("Sources", count: scope.count)
            if scope.sources.isEmpty {
                HPCard { HPMuted("Nothing is exposed.") }
            } else {
                HPListCard {
                    ForEach(Array(scope.sources.enumerated()), id: \.element.id) { index, source in
                        HPListItem(isLast: index == scope.sources.count - 1) {
                            HPMono("@" + source.username, color: HPTokens.Colors.ink)
                        } trailing: {
                            HPPill(source.kind.rawValue, tone: .neutral)
                        }
                    }
                }
            }
            HPMuted("Private chats are never included.")
        }
    }
}

/// PRODUCT §2.14: "`Custom` scope pushes an editable list of usernames with the same
/// availability check as feeds elsewhere."
struct ConnectorCustomScreen: View {
    @Environment(AppModel.self) private var model
    @State private var entry = ""

    var body: some View {
        let custom = model.connector.settings.custom
        Screen(back: true) {
            HPSectionMark("Custom sources", count: custom.count)
            HPCard {
                HPTextField("Add a channel or node", text: $entry, placeholder: "@channel", kind: .url) { add() }
                HPButton("Add", style: .neutral, size: .small, enabled: Username.normalise(entry) != nil) { add() }
            }
            if custom.isEmpty {
                HPCard { HPMuted("Nothing listed. An empty custom list exposes nothing.") }
            } else {
                HPListCard {
                    ForEach(Array(custom.enumerated()), id: \.element) { index, username in
                        HPListItem(isLast: index == custom.count - 1) {
                            HPMono("@" + username, color: HPTokens.Colors.ink)
                        } trailing: {
                            HPButton("Remove", style: .ghost, size: .small) {
                                model.connector.setCustom(custom.filter { $0 != username })
                            }
                        }
                    }
                }
            }
            HPMuted("Only these usernames are exposed. Private chats are never included.")
        }
    }

    private func add() {
        guard let username = Username.normalise(entry) else { return }
        var next = model.connector.settings.custom
        guard !next.contains(where: { Username.key($0) == Username.key(username) }) else { entry = ""; return }
        next.append(username)
        model.connector.setCustom(next)
        entry = ""
    }
}

#endif
