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
- **No hosted instance.** Nothing here may point at a host we run — there
  isn't one, and a URL that 404s is worse than no URL. A public web origin is
  optional per-deployment config; with none set, share actions hand out
  `t.me` links (`PUBLIC.md`, `PRODUCT §2.13`).
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
- **Commit messages** end with `Co-Authored-By: Ana Iliovic <ana-iliovic@users.noreply.github.com>`.
  Work on `main`, push direct.

## Layout

```
PROTOCOL.md  PRODUCT.md  README.md  AGENTS.md  LICENSE
design/      tokens.json, build.mjs, COMPONENTS.md, fonts/, swift/, kotlin/, web/
ios/         xcodegen project (project.yml), Sources/, Makefile, scripts/
android/     Gradle project, app/
web/         static site (index.html, js/, vendor/) — self-hosted, no deploy from here
docs/        App Store / Play listing copy, privacy policy, building + forking notes
```

## Deploy

**`web/` does not deploy anywhere.** There is no tgsocial web host and no
deploy hook; the directory is a static bundle a self-hoster copies to their
own origin, with their own `config.json` and the `/tg/s/` proxy from
`PUBLIC.md §1`. `web/README.md` is the instructions for them, not a runbook
for us — do not add a deploy step, a host, or a URL to it.

iOS ships out of its own Makefile — `make archive` → `make export` → `make
upload` (altool, App Store Connect key from `Secrets.xcconfig`, `ios/README.md`)
→ TestFlight. There is no root `scripts/`; every release step lives in the
platform directory it belongs to. Android ships through
`./gradlew :app:bundleRelease`.
