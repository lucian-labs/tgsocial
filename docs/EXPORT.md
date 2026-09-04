# tgsocial — export compliance

Why `ITSAppUsesNonExemptEncryption` is `true` in `ios/project.yml`, and what
that answer commits us to. This is a record of the reasoning behind a filed
declaration, not legal advice; the authorities are Apple's export compliance
documentation and the EAR itself.

## The declaration

**`true`.** It was `false`, and `false` was wrong.

`ITSAppUsesNonExemptEncryption: false` says the app uses no encryption, or
only encryption an exemption already covers. In practice that exemption is
aimed at apps whose cryptography is the operating system's: HTTPS through
`URLSession`, the keychain, file protection on disk. An app that talks to a
server over TLS and does nothing else is exactly the case the flag was
written for.

tgsocial is not that app. It links TDLib (`TDLibKit`, version pinned in
`ios/project.yml`), and TDLib implements **MTProto** — Telegram's own
transport cryptography — compiled into our binary rather than called out to
the system. That is a non-exempt cryptographic implementation that we ship,
and it does not matter that we did not write it: the question is what the
binary contains, not who authored it.

MTProto is the whole of it. TDLib can encrypt its binlog and its SQLite file,
but only when the caller hands it a key, and all three clients hand it an
empty one — `databaseEncryptionKey: nil` in
`ios/Sources/TDLib/TDClient.swift`, `databaseEncryptionKey = byteArrayOf()` in
`android/…/td/TelegramClient.kt`, and no key step at all in `web/js/td.js`.
TDLib reads an empty key as off (`TdDb.cpp`:
`encrypt_binlog = !parameters.encryption_key_.is_empty()`, and the SQLite flag
follows the binlog's), so the session database is written in the clear and
what protects it on disk is the platform's own file protection — the exempt
category, not this one. An earlier version of this file claimed a
TDLib-managed encrypted database and cited `docs/PRIVACY.md` for it; both were
wrong, and the mistake is named here because a compliance record's only job is
to be accurate about what the binary contains.

The fact is the same on all three builds — Android links the same TDLib, and
`web/vendor/tdweb` is TDLib compiled to wasm. Only Apple asks the question in
a form, so only the iOS project carries the key.

## What `true` costs

App Store Connect asks a follow-up on the first submission that carries this
flag, and again whenever the answer changes: whether the app qualifies for an
exemption anyway, and whether documentation (a CCATS, or an Encryption
Registration Number) is on file. There are two credible paths here, and they
want deciding before a public submission rather than in the middle of one.

**Path one — mass-market self-classification.** A consumer app using
published algorithms is normally classified `5D002` and exported under
License Exception ENC, `740.17(b)(1)`. The obligation that comes with it is an
**annual self-classification report**: one submission per calendar year, due
by 1 February for everything exported in the year before, in the format of
Supplement No. 8 to Part 742, emailed to BIS and the NSA. Per item it lists
the product name and version, the manufacturer, the ECCN, the authorising
paragraph, what the item does, and the algorithms and key lengths it uses —
for us, whatever MTProto itself uses, read out of TDLib's source rather than
guessed at. Nothing else in the binary belongs on that line; the local
database is unencrypted, as above. It is a form, not an application: there is
no approval to wait for, and no fee. Missing it is the compliance failure, not
filing it.

**Path two — publicly available source.** tgsocial is MIT and published, and
TDLib is Boost-licensed and published. Encryption source code that is
publicly available, and the object code compiled from it, sit outside the EAR
once a notification carrying the URL has gone to BIS and the NSA
(`742.15(b)`). That is a genuinely different footing from path one and it fits
this repo, but it turns on the binary we hand Apple being the published source
compiled — which is a claim about the release process, so it is only true
while it is true.

Either way the App Store answer stays `true`; the paths differ in what we owe
afterwards, not in what the binary contains. If we ever hold a CCATS or an
ERN, its code belongs in `ITSEncryptionExportComplianceCode` next to the flag,
and App Store Connect stops asking per submission.

Google Play has no equivalent form. The obligation is the exporter's either
way, so a decision made here covers that build too.

## Not the reason to change the answer

Declaring `false` because it makes the upload dialog shorter is the failure
mode this file exists to prevent. The flag is a statement to a regulator that
Apple relays; being wrong in it is a compliance problem that outlives any one
review.
