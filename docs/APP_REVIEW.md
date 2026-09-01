# Why Apple would reject tgsocial

An honest burndown, worst first. This is not a list of hypotheticals — items
1–4 are, as the app stands today, near-certain rejections rather than risks.
TestFlight will happily accept builds that App Review would refuse, so a
green TestFlight build says nothing about any of this.

Status key: **BLOCKER** = will be rejected. **LIKELY** = expect a reviewer to
raise it. **WATCH** = defensible, but be ready to answer.

---

## 1. BLOCKER — Guideline 1.2, user-generated content

This is the one that sinks social apps, and tgsocial currently has **none of
the four things the guideline requires**:

| Required | tgsocial today |
| --- | --- |
| A method for filtering objectionable material | none |
| A mechanism to report offensive content, with timely responses | none |
| The ability to block abusive users | none |
| Published contact information | not in the app |

The app shows an endless feed of arbitrary public Telegram channels. "The
content is Telegram's, not ours" is **not** an accepted answer — Apple holds
the app that displays the content responsible for the controls around it.

What has to exist before submission:

- **Report** on every post and every comment, reaching *us*, with a stated
  response commitment (Apple looks for 24 hours). Because the network has no
  server, this needs somewhere to land — an email endpoint or a moderation
  queue in GroundControl is the cheap version.
- **Block** a node, and **mute/hide** a feed. Blocking must be durable and
  must actually remove that node's posts and comments from every surface,
  including `/u/` pages and the +1 walk.
- **Filter**: at minimum, hide flagged/blocked content by default. A
  keyword/NSFW filter is stronger.
- **Contact info** visible in-app (the You screen footer) and on the listing.

This is real product work, not a checkbox — budget for it properly.

## 2. BLOCKER — Guideline 2.1, App Completeness (demo access)

Sign-in requires a phone number and an SMS/Telegram code. A reviewer cannot
get past the first screen. Apps in this position get rejected within hours
unless the review notes carry **working credentials**.

Options, in order of reliability:

1. A dedicated demo Telegram account whose phone we control, plus a way for
   the reviewer to receive the login code — the hard part, since codes go to
   the Telegram app or an SMS we hold. In practice this means a standing
   account already logged in on a device we can read, and giving the reviewer
   the code on request via the Resolution Center (slow, and it expires).
2. A **demo mode** that boots the app against canned data with no sign-in,
   toggled by a review-only credential typed into the phone field. This is
   the pragmatic answer and is common for phone-auth apps — but it must not
   look like hidden functionality (see §7).
3. Ship with a 2FA-free demo account and a login code delivered to an email
   the reviewer is given.

`docs/STORE_LISTING.md` already promises "a demo account phone number and the
current code can be supplied on request". That is not sufficient on its own —
codes expire faster than review turnarounds.

## 3. BLOCKER — Guideline 5.1.1(v), account deletion

The app **creates an account-like artifact**: on Setup it creates a public
Telegram channel (your node) and, on first comment, a second one. Any app
that supports account creation must let the user initiate deletion from
inside the app.

Today: Sign Out exists; **delete does not**. Needed: a destructive path that
deletes the node channel (and the comments channel), with a clear warning
that it removes the public card others read. `PROTOCOL §7` already says
signing out wipes local state — deletion is the missing half.

## 4. BLOCKER — age rating vs. content

`docs/STORE_LISTING.md` says **12+**. An app surfacing arbitrary public
Telegram channels — unfiltered, from a network with a reputation Apple is
well aware of — is not 12+. Expect to declare **17+** with "Frequent/Intense
Mature/Suggestive Themes" and unrestricted web access, or to implement real
filtering and argue for lower. Misdeclaring the rating is itself a rejection.

## 5. LIKELY — Guideline 2.5.1 / export compliance, encryption declaration

`ITSAppUsesNonExemptEncryption: false` is currently set in `project.yml`.
TDLib implements **MTProto**, Telegram's own cryptographic protocol — that is
not obviously within the "exempt" category the flag claims, which is aimed at
apps using only standard OS-provided crypto (HTTPS via URLSession, etc.).

Declaring this wrong is a compliance problem, not just a review one. Get it
right: most likely the answer is `true` plus a CCATS/self-classification
(many messaging apps file an annual self-report). This needs a real decision
before submission, not a default.

## 6. LIKELY — Guideline 4.2, minimum functionality / "just a client"

Third-party Telegram clients **do** ship (Swiftgram, Nicegram), so this is
survivable — but tgsocial is thinner than those: it is a reader over channels
plus a card format. A reviewer can reasonably ask what it does that the
Telegram app does not.

The answer exists and should be *in the review notes*: tgsocial is not a
Telegram client, it is a social network whose storage layer happens to be
Telegram — the card, the follow graph, the merged chronological feed and the
comment threads are all things Telegram itself does not do. Say that plainly
rather than hoping it is obvious.

## 7. LIKELY — Guideline 2.3.1, hidden or undocumented features

Two things to get ahead of:

- **The Connector** (`CONNECTOR.md`) runs a local HTTP server. It is
  `#if targetEnvironment(macCatalyst)`, so it should not be in the iOS
  binary at all. **Checked on the archive** (1.0.0 / 202609010235), not on the
  conditional: zero `Connector` symbols, no `bind`/`listen`/`accept`, no
  `NWListener`, no `127.0.0.1` / `8477` / `connector.json` strings, and no
  local-network keys in `Info.plist`. Re-run it on any archive that ships —
  a build-setting change is all it would take to put a listening socket in an
  iOS binary, and that is a bad conversation to have unprepared:

  ```bash
  BIN=ios/build/tgsocial.xcarchive/Products/Applications/tgsocial.app/tgsocial
  nm -a "$BIN" | grep -c Connector                                  # expect 0
  nm -u "$BIN" | grep -E '_bind$|_listen$|_accept$|nw_listener'     # expect none
  strings -a "$BIN" | grep -E '127\.0\.0\.1|connector\.json|8477'  # expect none
  ```
- Any **demo mode** added for §2 is by definition a hidden feature. Document
  it in the review notes explicitly; undocumented ones get rejected under
  this guideline.

## 8. WATCH — Guideline 5.1.1, Sign in with Apple

SIWA is required when an app uses a **third-party or social login service**
as its only sign-in. Telegram phone auth is arguably exactly that. The
counter-argument is that Telegram is not a "login service" here — it is the
backing store the app is a client of, the way an email client authenticates
to a mail provider. That argument usually holds for dedicated clients, but be
ready for it.

## 9. WATCH — trademark and identity

The listing must not imply Telegram endorsement. Do not use Telegram's mark
or logo in the icon or screenshots; describe it as "an independent
third-party client" (the listing already does). Also confirm the app name is
clear of Telegram's marks — "tgsocial" leads with `tg`, which is at least
adjacent. A rename is cheap now and expensive later.

## 10. WATCH — privacy nutrition labels vs. reality

The listing claims **no data collected**, which is true of us. Confirm the
label reflects that TDLib stores the session locally and that all network
traffic goes to Telegram — "not collected by the developer" is accurate, but
the reviewer may probe. `docs/PRIVACY.md` is consistent today; keep it that
way if a report/block backend is added for §1, because that **will** collect
data and the label must change with it.

## 11. WATCH — iPad

The app builds universal. If it looks like a stretched phone app on iPad,
expect a 4.0 design push-back. Either make the iPad layout deliberate or
declare iPhone-only.

---

## The shortest path to submittable

1. Report + block + filter + in-app contact (§1) — the largest piece.
2. Delete-my-node (§3).
3. A documented demo route (§2).
4. Fix the age rating (§4) and the encryption declaration (§5).
5. ~~Symbol-check the archive for the Connector (§7)~~ — done, and cheap to
   repeat per archive. Write the review notes covering the demo route and the
   "not just a client" argument (§6).

1–3 are product features that change the app. Nothing here is a reason not
to keep shipping to TestFlight — internal testing needs none of it — but
none of it is optional for public release.
