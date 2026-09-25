// Atproto — the wait between opening Bluesky's page and its redirect coming back (PROTOCOL.md
// §12.7 steps 6–7, PRODUCT.md §2.35).
//
// Why not ASWebAuthenticationSession: on Catalyst it hands the page to the default browser (Chrome,
// on Elijah's Mac), and the redirect `ca.lucianlabs:/tgsocial/oauth/callback` then only reaches the
// app through a scheme the app itself registers. With none registered the session waited forever
// — no timeout, no cancel — and sign-in sat on `Continue` (measured 2026-09-25). So the page opens
// in the system default browser (RFC 8252's external user agent, which is also what lets a browser
// already signed in to Bluesky count), the scheme is registered in project.yml, and the callback
// arrives as an ordinary URL open (`onOpenURL` → `receive`).
//
// What this type guarantees, each one a line of §12.7 step 7:
// - one attempt at a time;
// - a callback completes the attempt only when its `state` matches; anything else on our redirect
//   (unknown, stale, after cancel or timeout) is swallowed, and the pending attempt carries on;
// - the attempt always ends: on the callback, on `cancel()`, or at `timeout` (10 minutes).

import Foundation

@MainActor
final class AuthorizationWait {
    /// How an attempt ended without a callback.
    enum Ending: Error, Equatable { case cancelled, timedOut, busy, couldNotOpen }

    private struct Pending {
        let state: String
        let continuation: CheckedContinuation<URL, Error>
        let timer: Task<Void, Never>
    }

    let redirectURI: String
    /// PRODUCT §2.35: 10 minutes. Settable so a test measures the end without waiting ten minutes.
    var timeout: Duration = .seconds(600)
    /// Opens the page. `UIApplication.shared.open` in the app; a recorder in the tests.
    let openBrowser: @MainActor (URL) async -> Bool

    private var pending: Pending?

    init(redirectURI: String, openBrowser: @escaping @MainActor (URL) async -> Bool) {
        self.redirectURI = redirectURI
        self.openBrowser = openBrowser
    }

    var isWaiting: Bool { pending != nil }

    /// Opens `url` and suspends until the callback for `state`, a cancel, or the timeout.
    func wait(opening url: URL, state: String) async throws -> URL {
        guard pending == nil else { throw Ending.busy }
        let limit = timeout
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let timer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                self?.finish(state: state, .failure(Ending.timedOut))
            }
            pending = Pending(state: state, continuation: cont, timer: timer)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !(await self.openBrowser(url)) { self.finish(state: state, .failure(Ending.couldNotOpen)) }
            }
        }
    }

    /// A URL the app was asked to open. True when it is on our redirect — consumed whether or not it
    /// matched, so a stale callback never falls through to anything else — and false otherwise.
    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard Self.isCallback(url, redirectURI: redirectURI) else { return false }
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
        guard let p = pending, let state, state == p.state else { return true }
        finish(state: p.state, .success(url))
        return true
    }

    func cancel() {
        guard let p = pending else { return }
        finish(state: p.state, .failure(Ending.cancelled))
    }

    /// Ends the attempt for `state` once. A late timer or a second callback finds nothing to end.
    private func finish(state: String, _ result: Result<URL, Error>) {
        guard let p = pending, p.state == state else { return }
        pending = nil
        p.timer.cancel()
        p.continuation.resume(with: result)
    }

    /// Same scheme and path as the registered redirect (§12.7 step 7: "path is ours").
    nonisolated static func isCallback(_ url: URL, redirectURI: String) -> Bool {
        guard let got = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let want = URLComponents(string: redirectURI) else { return false }
        return got.scheme?.lowercased() == want.scheme?.lowercased() && got.path == want.path
    }
}
