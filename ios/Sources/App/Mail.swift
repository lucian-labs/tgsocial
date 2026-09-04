// App — the report email and the contact address (PRODUCT.md §2.15, §2.19).
//
// With no server there is nothing to report *to*, so a report is an email the reader's own mail
// client sends. The app fills in a subject and a body and then gets out of the way: the reporter's
// address is whatever their mail client sends, and they can edit or delete every line before
// sending. Nothing about the safety lists (PROTOCOL §7.1) goes anywhere near it.

import Foundation
import MessageUI
import UIKit

/// What is being reported (PRODUCT §2.15). Built from a `Post` or a `Comment` so the report confirm,
/// the email and the hidden list all name the same thing.
struct ReportSubject: Equatable, Hashable {
    enum Kind: String, Equatable, Hashable { case post, comment }

    var kind: Kind
    /// The channel the reported message lives in: the source feed for a post, the commenter's
    /// comments channel for a comment.
    var channel: String
    var serverMessageId: Int64
    /// The attributed node (§2.3) — the commenter's node on a comment. Nil reads `unattributed`.
    var node: String?

    var link: String { "https://t.me/\(channel)/\(serverMessageId)" }
    /// Where it lands on the hidden list (PROTOCOL §7.1).
    var hiddenKey: String { Moderation.key(channel: channel, serverMessageId: serverMessageId) }

    /// `Report this post.` / `Report this comment.`
    var title: String { kind == .post ? "Report this post." : "Report this comment." }
    /// `Report Post` / `Report Comment`
    var buttonLabel: String { kind == .post ? "Report Post" : "Report Comment" }

    init(post: Post) {
        kind = .post
        channel = post.sourceUsername
        serverMessageId = DeepLink.serverMessageId(post.messageId)
        node = post.authorUsername
    }

    init(comment: Comment) {
        kind = .comment
        channel = comment.channelUsername
        serverMessageId = DeepLink.serverMessageId(comment.messageId)
        node = comment.ownerUsername
    }
}

/// The email, composed (PRODUCT §2.15). Pure, so the exact bytes can be asserted.
enum ReportMail {
    static let to = Moderation.contactAddress

    /// `tgsocial report — <reason>`, the reason verbatim from the §2.15 list.
    static func subject(reason: String) -> String { "tgsocial report \u{2014} " + reason }

    /// The body ends on a blank line so the composer's cursor lands under the prompt. The app adds
    /// nothing else — no phone number, no device id.
    ///
    /// `prefix` is the single exception, written down in PRODUCT §2.22.2: a report sent from the
    /// demo leads with a line saying so, because the link in it points at a channel that does not
    /// exist and the operator would otherwise go looking for it.
    static func body(subject s: ReportSubject, reason: String, app: String, prefix: String? = nil) -> String {
        var lines = [
            "Reason: " + reason,
            "Link: " + s.link,
            "Channel: @" + s.channel,
            "Message: " + String(s.serverMessageId),
            "Node: " + (s.node.map { "@" + $0 } ?? "unattributed"),
            "Kind: " + s.kind.rawValue,
            "App: " + app,
        ]
        if let prefix, !prefix.isEmpty { lines.insert(prefix, at: 0) }
        return lines.joined(separator: "\n") + "\n\nAnything you want to add:\n\n"
    }

    /// The `mailto:` fallback when no composer is configured. Percent-encoded per RFC 3986; the
    /// subject's em dash and the body's newlines both have to survive the trip.
    static func mailto(to address: String = ReportMail.to, subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        var items: [URLQueryItem] = []
        if !subject.isEmpty { items.append(URLQueryItem(name: "subject", value: subject)) }
        if !body.isEmpty { items.append(URLQueryItem(name: "body", value: body)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }
}

/// Everything `MailLauncher` needs from the platform: whether a composer can be shown, how to show
/// it, and how to hand a `mailto:` URL to the system. A value rather than three calls into UIKit so
/// the composer branch can be exercised — a simulator has no mail account, and *when* the
/// completion runs on that branch is what PRODUCT §2.15's toast depends on.
@MainActor
struct MailPlatform {
    var canSendMail: () -> Bool = { MFMailComposeViewController.canSendMail() }
    /// `false` means nothing was presented — there was no controller to present on.
    var present: (MFMailComposeViewController) -> Bool = { composer in
        guard let host = MailLauncher.topController else { return false }
        host.present(composer, animated: true)
        return true
    }
    var open: (URL, @escaping (Bool) -> Void) -> Void = { url, done in
        guard UIApplication.shared.canOpenURL(url) else { done(false); return }
        UIApplication.shared.open(url, options: [:]) { opened in
            Task { @MainActor in done(opened) }
        }
    }
}

/// Opens the platform's mail composer: `MFMailComposeViewController` when mail is configured, else
/// `mailto:` through `openURL` (PRODUCT §2.15). `completion(false)` means nothing opened — the
/// caller has already hidden the content and only the toast changes.
@MainActor
final class MailLauncher: NSObject, MFMailComposeViewControllerDelegate {
    static let shared = MailLauncher()

    var platform = MailPlatform()

    /// The completion of the composer currently on screen. §2.15's toast is the only sign that the
    /// report was recorded and the content hidden, and the toast host is a SwiftUI overlay in
    /// RootView — *underneath* a presented composer, with its auto-dismiss already counting down.
    /// Firing at `present` therefore paints the confirmation behind the sheet and expires it while
    /// the reader is still writing the mail, so the completion waits for the composer to go away.
    private var pending: ((Bool) -> Void)?

    func send(to address: String, subject: String, body: String, completion: @escaping (Bool) -> Void) {
        if platform.canSendMail() {
            let composer = MFMailComposeViewController()
            composer.mailComposeDelegate = self
            composer.setToRecipients([address])
            composer.setSubject(subject)
            composer.setMessageBody(body, isHTML: false)
            if platform.present(composer) {
                pending = completion
                return
            }
        }
        guard let url = ReportMail.mailto(to: address, subject: subject, body: body) else {
            completion(false)
            return
        }
        platform.open(url, completion)
    }

    /// The composer is off the screen, so the toast it would have hidden can be read: this is
    /// where the composer branch's completion runs. Separate from the delegate callback below
    /// because the callback is UIKit plumbing and this is the app's own decision.
    func composerClosed() {
        let finish = pending
        pending = nil
        finish?(true)
    }

    /// UIKit calls this on the main thread; `assumeIsolated` says so rather than hopping through a
    /// Task and carrying a non-Sendable controller across the boundary.
    ///
    /// The result is not consulted: §2.15 hides the content whether or not the mail was actually
    /// sent, so cancelling gets the same toast as sending. What matters is that the toast is
    /// emitted after the dismissal, not before it.
    nonisolated func mailComposeController(_ controller: MFMailComposeViewController,
                                           didFinishWith result: MFMailComposeResult, error: Swift.Error?) {
        MainActor.assumeIsolated {
            controller.dismiss(animated: true) { self.composerClosed() }
        }
    }

    /// The modal stack is the app's own overlay (`hpModal`), not a presented controller, so this is
    /// normally the root — but a composer must never be presented on a controller that is already
    /// presenting something, so the walk stays.
    fileprivate static var topController: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
}
