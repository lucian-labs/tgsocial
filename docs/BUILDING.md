# Building tgsocial yourself

Anyone can clone this repo and put tgsocial on their own phone. There is no
server to run and no account to create — you need a Telegram account, your
own free Telegram API credentials, and the platform toolchain.

## 0. Get API credentials (all platforms, 2 minutes)

1. Sign in at https://my.telegram.org/apps with your Telegram account.
2. Create an application (any name/short name; platform "Other").
3. Note the `api_id` (a number) and `api_hash` (a hex string). They identify
   your *build* to Telegram, not your account; keep them out of git. Every
   fork must use its own pair — see [FORKING.md](./FORKING.md).

## 1. iOS — build direct to your iPhone

Requirements: a Mac with Xcode 16+ (26 recommended), [xcodegen]
(`brew install xcodegen`), an Apple ID. A paid developer account is NOT
required — a free Apple ID signs builds that run on your own device for
7 days at a time (rebuild to renew).

```bash
git clone https://github.com/lucian-labs/tgsocial && cd tgsocial/ios
cp Secrets.xcconfig.example Secrets.xcconfig    # fill in TG_API_ID / TG_API_HASH
make gen                                        # generates tgsocial.xcodeproj
open tgsocial.xcodeproj
```

In Xcode: Signing & Capabilities → set **Team** to your personal team and
change the **bundle identifier** to something you own (e.g.
`com.yourname.tgsocial` — free accounts can't use ours). Plug in your
iPhone, trust the Mac, select the device, Run. On device: Settings →
General → VPN & Device Management → trust your developer certificate.

Command line instead of Xcode (paid account with a team id):

```bash
make device DEVICE_ID=<udid from `xcrun devicectl list devices`>
```

First build downloads TDLibKit's ~360 MB framework and compiles its
generated API — expect 10–15 minutes once, minutes after.

## 2. Android — build direct to your phone

Requirements: JDK 17+ and the Android SDK (easiest: install Android Studio;
the Gradle wrapper fetches Gradle itself).

```bash
git clone https://github.com/lucian-labs/tgsocial && cd tgsocial/android
cp secrets.properties.example secrets.properties   # fill in TG_API_ID / TG_API_HASH
# point local.properties at your SDK if Studio hasn't already:
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties
./gradlew :app:installDebug        # phone plugged in, USB debugging on
```

Or open `android/` in Android Studio and press Run. The debug build is
signed with your local debug key — that's all sideloading needs.

## 3. Web — host it anywhere static

```bash
git clone https://github.com/lucian-labs/tgsocial && cd tgsocial/web
cp config.json.example config.json   # fill in apiId / apiHash
python3 -m http.server 8080          # or any static host, at the ORIGIN ROOT
```

Serve over https in production (Telegram's transport is `wss:`; the page
must be a secure context). nginx should send `.wasm` as `application/wasm`.
The bundled TDLib wasm in `web/vendor/tdweb/` was compiled from
[tdlib/td] by `web/tdweb-build/Dockerfile`; rebuild it yourself with
`docker build -t tdweb-build web/tdweb-build && docker run --rm
-v "$PWD/web/vendor/tdweb:/out" tdweb-build` if you don't want to trust
our binary — the dist records the TDLib commit in `TD_COMMIT`.

## 4. Tests

```bash
cd ios && make test                        # card vectors + merge tests
cd android && ./gradlew :app:testDebugUnitTest
cd web && node test/protocol.test.mjs && node test/smoke.mjs
```

All three load the same [docs/card-vectors.json](./card-vectors.json), so a
fork that passes them still speaks the protocol.

[xcodegen]: https://github.com/yonaskolb/XcodeGen
[tdlib/td]: https://github.com/tdlib/td
