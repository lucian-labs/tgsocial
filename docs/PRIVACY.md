# tgsocial — privacy policy

Effective 2026-08-23.

tgsocial is a third-party Telegram client. It has no server of its own.

**What it stores.** Telegram's client library (TDLib) keeps an encrypted
local database on your device containing your session, the chats you've
loaded, and cached media. tgsocial adds a pointer to your node channel, a
cache of the cards it has read, and interface preferences. All of it stays on
the device. Signing out deletes all of it.

**What it sends.** Everything tgsocial does is an ordinary Telegram API call
made directly from your device to Telegram's servers, authenticated as you.
There is no analytics, no crash reporting, no telemetry, and no third-party
SDK. The web build makes no request to any host other than Telegram and the
page that served it.

**What it publishes.** Your node is a public Telegram channel. Its card —
your display name, bio, link, the feeds you list, and the nodes you follow —
is readable by anyone on Telegram, by design. You choose what goes on it,
and you can edit or delete the channel from any Telegram client.

**What it does not do.** It does not read your private chats, contacts, or
messages beyond the channels you open. It does not create Telegram accounts.
It does not sell or share anything, because it never has anything.

**Telegram.** Your use of Telegram is governed by Telegram's own privacy
policy at https://telegram.org/privacy.

Questions: elijah@lucianlabs.ca. Source: https://github.com/lucian-labs/tgsocial.
