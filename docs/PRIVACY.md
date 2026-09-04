# tgsocial — privacy policy

Effective 2026-09-04.

tgsocial is a third-party Telegram client. It has no server of its own.

**What it stores.** Telegram's client library (TDLib) keeps a local database
on your device containing your session, the chats you've loaded, and cached
media. It lives in the app's private storage, protected by whatever your
device gives that storage; tgsocial adds no encryption of its own on top of
it. tgsocial also stores a pointer to your node channel, a cache of the cards
it has read, interface preferences, and the nodes you have blocked, the feeds
you have muted, and the posts you have reported. All of it stays on the
device. Signing out deletes all of it except the block, mute and report
lists, which are kept so that signing back in does not put someone you blocked
back in front of you; signing in as a different account replaces them with
empty ones.

**What it sends.** Everything tgsocial does is an ordinary Telegram API call
made directly from your device to Telegram's servers, authenticated as you.
There is no analytics, no crash reporting, no telemetry, and no third-party
SDK. The web build makes no request to any host other than Telegram and the
page that served it. Reporting a post or a comment opens your own mail app
with a message to elijah@lucianlabs.ca containing a link to the reported
content and the reason you picked; you can edit or discard it before sending,
and the app sends nothing itself.

**What it publishes.** Your node is a public Telegram channel. Its card —
your display name, bio, link, the feeds you list, and the nodes you follow —
is readable by anyone on Telegram, by design. You choose what goes on it,
and you can edit or delete the channel from any Telegram client.

**What it does not do.** It does not read your private chats, contacts, or
messages beyond the channels you open. It does not create Telegram accounts.
It does not sell or share anything, because it never has anything. Your block
and mute lists are yours alone: they are not written to your public card, not
sent to Telegram, and not visible to anyone else, and the people you block
are not told.

**Telegram.** Your use of Telegram is governed by Telegram's own privacy
policy at https://telegram.org/privacy.

Questions: elijah@lucianlabs.ca. Source: https://github.com/lucian-labs/tgsocial.
