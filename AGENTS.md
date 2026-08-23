# AGENTS.md — tgsocial

Rules for any agent working in this repo. `CLAUDE.md` points here.

## Read first

1. `PROTOCOL.md` — the wire contract. Every platform implements it exactly.
   Change the protocol there first, then in all three clients in the same
   commit.
2. `PRODUCT.md` — screens, flows, copy. Copy is shared; do not improvise
   strings on one platform.
3. `design/COMPONENTS.md` — the component contract, and upstream
   `https://lucianlabs.ca/branding/AGENT.md` for the ban list.

## Hard rules

- **No secrets in the tree.** `api_id`/`api_hash` come from
  `ios/Secrets.xcconfig`, `android/secrets.properties`, `web/config.json`
  — all gitignored, each with a committed `.example`.
- **No server.** If a feature needs a backend, it is out of scope for this
  repo; the whole point is that Telegram is the backend.
- **Tokens, never values.** Colours, radii, spacing, type come from
  `HPTokens` / `var(--token)`. Zero raw hex outside `design/tokens.json`.
  Regenerate with `node design/build.mjs --sync`; never edit generated files.
- **One look.** House Pour everywhere. No system chrome leaking through
  (native tab bars, nav bars, switches, segmented controls, Material
  components).
- **Chronological.** The main feed is merged by date. No ranking code.
- **Build before reporting.** iOS: `cd ios && make build`. Android:
  `cd android && ./gradlew :app:assembleDebug`. Web: `cd web && node
  test/smoke.mjs`. A change is not done until its build passes.
- **Commit messages** end with `Co-Authored-By: Ana Iliovic <ana@thevii.app>`.
  Work on `main`, push direct.

## Layout

```
PROTOCOL.md  PRODUCT.md  README.md  AGENTS.md  LICENSE
design/      tokens.json, build.mjs, COMPONENTS.md, fonts/, swift/, kotlin/, web/
ios/         xcodegen project (project.yml), Sources/, Makefile
android/     Gradle project, app/
web/         static site (index.html, js/, vendor/), deployed to tgsocial.lucianlabs.ca
scripts/     device install, archive, release helpers
docs/        App Store / Play listing copy, privacy policy, screenshots
```

## Deploy

`web/` deploys by webhook on push to `main` (GroundControl target
`tgsocial.lucianlabs.ca`, buildCmd copies the host-side `config.json` in).
Never SSH, rsync, or run deploy scripts by hand. iOS ships through
`scripts/archive.sh` → TestFlight; Android through `./gradlew :app:bundleRelease`.
