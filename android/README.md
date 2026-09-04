# tgsocial — Android

Kotlin + Jetpack Compose, minSdk 26, targetSdk 35. TDLib via
[`dev.g000sha256:tdl-coroutines`](https://github.com/g000sha256/tdl-coroutines) 13.0.0 (TDLib 1.8.65).
No server: every call goes from the device to Telegram.

## Layout

```
app/src/main/kotlin/ca/lucianlabs/tgsocial/
  protocol/   pure Kotlin, no Android/TDLib imports — Card parse/serialise, Username, Backlink, DeepLink, Format, FeedMerge
  td/         TelegramClient — one TDLib client per process, update collectors attached before the first request, FLOOD_WAIT backoff
  repo/       LocalStore (DataStore + JSON caches), NodeRepo, MyNodeRepo, FeedRepo, DiscoveryRepo, PostingRepo, MediaRepo, TdMappers
  model/      MyNode pointer, NodeSnapshot (card cache entry), FeedSource, Post
  ui/         AppViewModel (StateFlows), enum-route navigation, screens/, components/
../../design/kotlin/housepour/   the House Pour kit: generated HousePourTokens.kt + hand-written HP* composables (compiled into :app)
```

## Configure secrets

```bash
cp secrets.properties.example secrets.properties   # TG_API_ID / TG_API_HASH from https://my.telegram.org/apps
printf 'sdk.dir=%s\n' "$HOME/Library/Android/sdk" > local.properties
```

Both files are gitignored. `app/build.gradle.kts` reads them into `BuildConfig.TG_API_ID` / `BuildConfig.TG_API_HASH`.
`TGS_PUBLIC_ORIGIN` is optional (PRODUCT §2.13): set it to the origin of a public reader you host yourself
(`PUBLIC.md`) and `Copy Link` copies `https://<origin>/f/<channel>`; leave it unset — the default — and
`Copy Link` copies the `t.me` link, which needs no server of your own.
A release keystore is optional: put `release.keystore` next to `secrets.properties` with
`RELEASE_STORE_PASSWORD`, `RELEASE_KEY_ALIAS`, `RELEASE_KEY_PASSWORD` in `secrets.properties`; without it the
release build signs with the debug key so `assembleRelease` / `bundleRelease` still succeed.

## Build, run, test

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"   # JDK 17+
./gradlew :app:assembleDebug :app:testDebugUnitTest      # debug APK + protocol unit tests
./gradlew :app:installDebug                               # onto a connected device
./gradlew :app:assembleRelease :app:bundleRelease         # APK + AAB, arm64-v8a + armeabi-v7a
```

Unit tests (`app/src/test`) load `../docs/card-vectors.json` — the Gradle task `copyCardVectors` copies it into
the test resources before every test run, so the single source stays in `docs/`.

## Notes

- Fonts live in `app/src/main/res/font/` (synced by `node design/build.mjs --sync`); the kit resolves them by
  name so it stays free of the app's `R` class.
- The only XML colour (`hp_backdrop`, the window background before the first Compose frame) is generated from
  `design/tokens.json` at build time.
- Adaptive launcher icons are generated from `design/icon/adaptive-*.png`; the 512 Play icon is `playstore-icon.png`.
