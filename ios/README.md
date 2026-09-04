# tgsocial — iOS and Mac

SwiftUI, iOS 17+, iPhone and iPad, plus a Mac Catalyst build of the same target. TDLib via
[Swiftgram/TDLibKit](https://github.com/Swiftgram/TDLibKit) (pinned `1.5.2-tdlib-1.8.66-022d6020`).
No server; every call is a TDLib call to Telegram.

The Mac build adds the Connector — a loopback HTTP bridge and the fifth tab that governs it
([`CONNECTOR.md`](../CONNECTOR.md), [PRODUCT §2.14](../PRODUCT.md)). It is compiled behind
`#if targetEnvironment(macCatalyst)` and does not exist in the iOS build at all.

## Configure secrets

```bash
cp Secrets.xcconfig.example Secrets.xcconfig   # gitignored
# fill in TG_API_ID / TG_API_HASH from https://my.telegram.org/apps
```

`Secrets.xcconfig` is the build configuration for both Debug and Release. The values flow into
`Info.plist` as `TGApiId` / `TGApiHash` and are read at runtime from `Bundle.main.infoDictionary`
(`TGSecrets.fromBundle()`). Nothing is hardcoded; the app shows a developer-facing card if they are missing.
The same file optionally carries `TGS_PUBLIC_ORIGIN` — the origin of a public reader you host
yourself ([PRODUCT §2.13](../PRODUCT.md), [`PUBLIC.md`](../PUBLIC.md)). There is no hosted tgsocial,
so it is unset by default and `Copy Link` copies the `t.me` link instead; set it and the absolute
`/f/` and `/n/` links come back (`PublicLink`, `Sources/Protocol/Links.swift`). Write it as
`https:/$()/host` — xcconfig treats `//` as the start of a comment, so a plain `https://host` sets
the value to `https:` and comments the host away. Only a scheme-and-host origin is accepted;
anything else (including that truncation) is treated as unset, and sharing stays on `t.me`.
It also carries
`ASC_API_KEY` / `ASC_API_ISSUER` (App Store Connect API key id and
issuer id) for `make upload`; environment variables of the same names override them.

## Build, run, test

```bash
make gen      # `xcodegen generate` → tgsocial.xcodeproj (gitignored; regenerate after editing project.yml)
make build    # Debug, iOS Simulator (iPhone 17 Pro)
make test     # unit tests: docs/card-vectors.json + feed merge
make device   # Debug build, install and launch on the registered iPhone
make archive  # Release archive → build/tgsocial.xcarchive (build number = UTC minute stamp, or BUILD_NUMBER=n)
make export   # App Store Connect export → build/export/tgsocial.ipa
make upload   # altool upload; ASC_API_KEY / ASC_API_ISSUER from Secrets.xcconfig or the environment
```

### Mac Catalyst

```bash
make mac-build  # Debug, destination 'platform=macOS,variant=Mac Catalyst' → build/derivedDataMac
make mac-test   # the same, running the tests — including the Connector suite
make mac-tdlib  # resolve packages + patch the TDLib xcframework (both other targets depend on it)
```

Its own `-derivedDataPath` (`build/derivedDataMac`): the two flows build the same scheme for
different platforms, and sharing one would have each invalidate the other's module cache.

`make test` runs on the simulator, where the Connector compiles to nothing — the Connector suite
lives in `make mac-test`.

**The xcframework patch.** `TDLibFramework.xcframework` ships ios, ios-simulator, macos, tvos,
watchos and xros slices, but no `ios-*-maccatalyst`, so a Catalyst link fails outright:

```
ld: building for 'macCatalyst', but linking in object file (…ConcurrentScheduler.cpp.o) built for 'macOS'
```

`scripts/tdlib-maccatalyst.py` derives the missing slice from the macos one, rewriting each object's
`LC_BUILD_VERSION` platform stamp from macOS to MACCATALYST. TDLib is platform-agnostic C++ — no
AppKit, no UIKit, just libc++, zlib and BSD sockets — so the objects are already correct code for
`arm64-apple-ios-macabi`; only the label disagreed. Four bytes per load command change and nothing
else, so the Catalyst build links the same code the iOS build does. The script is idempotent and
runs from `make mac-tdlib`; deleting the slice or the whole DerivedData just makes the next build
recreate it.
The first build resolves the TDLib xcframework (≈360 MB download, 1.3 GB unpacked) into
`build/SourcePackages`; every `xcodebuild` passes `-clonedSourcePackagesDirPath build/SourcePackages`
and `-derivedDataPath build/derivedData` so it is only fetched once.

## Layout

```
Sources/
  App/        tgsocialApp, AppModel (@Observable, @MainActor), RootView (shell + navigation)
  TDLib/      TDClient (client lifecycle, update routing, SendTracker, TDFailure)
  Protocol/   Card, Username, Links (deep link, backlink, index group), Formatters, FeedMerge — pure Swift
  Repo/       Models, LocalStore, Mapping, NodeRepository, FeedRepository, DiscoveryRepository, MediaLoader
  Components/ Scaffold (topbar, status pill), PostCard, Rows (NodeRow, FeedRow, EmptyCard), RichTextView, RemoteImage
  Screens/    SignIn, Setup (+ FeedsCard), Feed, Explore, NodeProfile, FeedChannel, Graph, You (+ modals), Compose
  Connector/  Mac only. Scope, token + handshake file, audit, wire, router, NWListener, service, screen
Tests/        CardVectorTests (loads ../docs/card-vectors.json), FeedMergeTests, media/memory,
              ConnectorTests + ConnectorBridgeTests (Catalyst only)
Resources/    Assets.xcassets (AppIcon, AccentColor, LaunchBackground), PrivacyInfo.xcprivacy
../design/swift/HousePour/   the House Pour kit (HP* views) + generated HousePourTokens.swift
```

`Protocol/` has no TDLib or SwiftUI imports, so the parser, serialiser, username rules, deep links,
backlinks, time/count formatting and the k-way feed merge are unit-tested against the shared vectors.

`Connector/` reads through the same repositories the app does — it is a second reader of one model,
not a second TDLib session — and its scope check has exactly one door: reads take a `ScopedSource`,
whose initialiser is private to `ConnectorScope.swift`, so the only way to name a chat is to have
passed `ScopeResolution.admit`. `tgsocial-Mac.entitlements` carries the sandbox grants Catalyst
needs: `network.server` for the loopback listen, `network.client` for TDLib, and a one-directory
home-relative exception so the handshake lands in the real `~/.tgsocial` where the MCP server looks.

## Tokens

Colours, radii, spacing, type and motion come from `design/swift/HousePour/HousePourTokens.swift`
(generated by `node design/build.mjs --sync`; never edited by hand). The target compiles the kit
directory as-is. The type ramp is the nested enum `` HPTokens.`Type` `` — backticked because `Type`
is reserved for nested type members — and the kit refers to it as `HPType`.

## Generated files

`tgsocial.xcodeproj/` and `Info.plist` are products of `make gen` and are gitignored; `project.yml`
is the source of truth.
