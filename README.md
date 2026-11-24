# Filament

One deliberate strand of your feed.

Filament is a native iOS Instagram client with the algorithmic surface removed:
no Explore, no Reels, no suggested posts, no engagement bait — a chronological
feed of the people you follow, rendered in SwiftUI, with a Rust core doing the
JSON work.

It is a fork of [Strand](https://github.com/ericssonl07/instagram-strand) by
Ericsson Lin (GPL-3.0), rebranded as its own client and reworked for speed.

## What changed from upstream

**Its own client.** Renamed throughout: the Xcode project and target are
`Filament`, the bundle id is `com.filament.client`, the app struct is
`FilamentApp`, and the upstream author's development team id and stale
`xcuserdata` were dropped.

**A Rust core for the hot path.** The one genuinely hot unit — turning
Instagram's JSON into models on the main actor for every feed page, tray, story
and comments load — is ported to Rust in `rust/filament-core`. Rust parses the
response, drops ads and suggested blocks, picks image candidates, and returns a
flat pre-filtered document that Swift decodes in one cheap pass instead of
walking Instagram's whole nested DTO tree.

**Caching that was missing.** `URLCache.shared` is given 64 MB memory / 512 MB
disk at launch; the default 512 KB is why re-scrolled photos downloaded again.
`ImagePrefetcher` warms the cache for each newly loaded page (skipped on
cellular and in Low Data Mode).

See `RUST-PORT.md` for the profiling, the port plan, the recorded cases and the
gate — including what still needs a Mac.

## How it works

Filament is not a `WKWebView` pointed at instagram.com with CSS hidden:

- **Reads** (feed, stories, comments, profile data) come from a hidden, logged-in
  `WKWebView` that executes `fetch()` inside Instagram's own page origin, so real
  cookies, CSRF tokens and anti-abuse headers attach automatically. Responses are
  mapped to native models and rendered entirely in SwiftUI.
- **Writes** (likes, comments) are driven through Instagram's own web UI in a
  hidden webview — an action it trusts, and one the user never sees. The raw
  write endpoints are only a last resort: they carry none of the integrity
  tokens its page JavaScript attaches, and being flagged for them applies to
  every endpoint, not just the write.
- **Login** uses a plain `WKWebView` showing Instagram's genuine page, so
  credentials and 2FA never touch native code.
- **Messages and Profile are native**: the inbox, threads, message bubbles and
  composer, and the profile header, counts and post grid are all SwiftUI fed by
  `direct_v2` and `/users/{pk}/info/`. Instagram's web DM UI is reachable only
  from the Messages error state, as a fallback.

### Getting told to "slow down"

Instagram rate-limits accounts that behave like a bot: once it answers
`feedback_required` ("please wait a few minutes"), **every further request
restarts its timer**. Each screen used to retry independently — the tab tasks,
the manual Retry buttons, the DM poll loop — so the block could never clear and
all three tabs were dead.

One object now owns that state, `Managers/RequestGovernor.swift`:

- A single cooldown, escalated 1m → 3m → 10m → 20m → 30m when it happens again,
  persisted in `UserDefaults` so relaunching does not immediately re-trigger it.
- While it holds, the bridge refuses to send anything at all — no webview call,
  no network, no pacing wait. Not a retry, not a poll.
- Pacing between calls widens automatically after a strike.

`Managers/ResponseCache.swift` keeps every successful body, in memory and on
disk, with a per-endpoint TTL (feed 60s, inbox 45s, profile 5m, current user
10m). Two consequences: revisiting a tab inside its TTL sends nothing, and
during a cooldown the last good body is served instead of an error, so the app
shows slightly stale content rather than three blank screens. `SlowedDownBanner`
says so, counts the cooldown down, and offers Retry only once it can work.

Other cuts to the request volume: identical in-flight requests are coalesced,
the DM poll moved from 6s to 20s and stops while cooling or after a failure, the
stories tray waits for the first feed page instead of starting with it, and a
failed refresh no longer wipes what is already on screen.

### Request formats, verified against live clients (Nov 2026)

Route shapes are no longer guessed; each was checked against
[`teslashibe/instagram-go`](https://github.com/teslashibe/instagram-go) — whose
README documents which endpoints are live-verified — and
[`MatheusOliveira-dev/igflare`](https://github.com/MatheusOliveira-dev/igflare),
which extracts its headers and GraphQL queries from the official Android app:

- `/api/v1/feed/timeline/` takes a full form body, not a bare `reason=...`:
  `is_pull_to_refresh`, `phone_id`, `battery_level`, `is_charging`,
  `will_sound_on` alongside `reason`/`max_id`.
- `/api/v1/feed/reels_media/` is **POST** with one `reel_ids[]` per reel and
  `source=reel_feed_timeline`, not a GET with a comma-joined `reel_ids`.
- `markStorySeen` exists now: `POST /api/v2/media/seen/` with
  `reels[<reel_id>][]=<media_pk>_<reel_id>_<taken_at>`, called once per segment
  from the player. Missing it is one reason sessions get flagged.
- DMs: inbox drops the ignored `folder`/`use_unified_inbox` combo for
  `limit`/`thread_message_limit=1`/`visual_message_return_type=unseen`; threads
  send the same `limit`/`visual_message_return_type`; sending repeats
  `client_context` as `mutation_token` and derives `offline_threading_id` from
  it (SHA-256 of the context, 63 bits), so a retry can't duplicate.
- Identity: `currentUser()` resolves through `/users/{ds_user_id}/info/`
  instead of `/accounts/current_user/`, which both references say answers
  redirect-to-login on healthy web sessions. A redirect on an already-validated
  session is treated as a **soft block** (cooldown, not logout) — only a real
  rejection clears cookies and returns to the login screen.
- Pacing: reads at ~4s apart, writes at ~12s; the exported instagram-go
  budgets are ~15 reads/min and ~1 write/min. `RequestGovernor.pacedInterval`
  is the one place these live.

`InstagramAPIBridge.lastFailure` keeps what Instagram literally answered —
endpoint, status and the first 180 characters of the body — and the banner shows
it, so a problem can be reported precisely instead of as "it says slow down".

When a cooldown expires on its own, any screen with nothing to show reloads
itself (`RequestGovernor.cooldownEnded`), so the app recovers without anyone
tapping Retry.

## Features

| Area | Status | Notes |
|---|---|---|
| Feed | Native | Chronological, cursor-paginated, like/comment/share, no ranking or injected ads. |
| Stories | Native | Tray + fullscreen player: progress bars, tap-to-advance, hold-to-pause, swipe-to-dismiss, video via AVKit. |
| Comments | Native | Read from the API; posting goes through the same API-first path. |
| Messages | Native | Inbox, threads, bubbles and a composer over `direct_v2`; 20s polling while a thread is open. |
| Profile | Native | Header with counts, bio and the post grid, paginated. |
| Authentication | Complete | Real Instagram login page in-app; credentials never touch native code. |

Deliberately absent: Reels, Explore, Suggested Posts.

## Building an IPA

`.github/workflows/ios-ipa.yml` builds the app for a real device on a
`macos-26` runner and publishes the result as a release asset, so there is a
stable download link:

**https://github.com/urosevicemanuel54-maker/Filament/releases/download/latest-build/Filament-unsigned.ipa**

The link always serves the newest successful build. It runs on every push to
`main`, on `v*` tags, and on demand from the Actions tab; the same file is also
attached to the run as an artifact.

**The default IPA is unsigned.** It cannot be installed on a stock iPhone as-is:
re-sign it with your own Apple ID using Sideloadly, AltStore or ESign (free
accounts need to re-sign every 7 days). That is the trade-off of building
without an Apple Developer account in CI.

To get a signed IPA instead, add these repository secrets
(Settings → Secrets and variables → Actions) and the workflow switches to an
archive/export build automatically:

| Secret | Value |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | your `.p12` signing certificate, base64 encoded |
| `P12_PASSWORD` | the `.p12` password |
| `PROVISIONING_PROFILE_BASE64` | the `.mobileprovision`, base64 encoded |
| `TEAM_ID` | your Apple Developer team id |
| `EXPORT_METHOD` | optional: `ad-hoc` (default), `development`, `app-store` |

The same workflow also runs the Rust core's tests (`cargo test` in
`rust/filament-core`), which is the gate `RUST-PORT.md` refers to.

## Requirements


- Xcode with the iOS 26 SDK, Swift 5
- An Instagram account (login is interactive, in-app — no credentials or API keys
  live in the project)
- Optional: Rust and `rust/filament-core/build-ios.sh` for the Rust decode path

## Getting started

1. Open `Filament.xcodeproj`, pick a simulator or device, and run.
2. Log in with your Instagram account.

The app builds and runs with no Rust toolchain: `Filament/Managers/FastDecode.swift`
selects the Rust backend only when `FilamentCore.xcframework` is in the project
(`#if canImport(FilamentCore)`), and otherwise uses the Swift reference
implementation of the same mapping.

## Architecture

```
Filament/
├── FilamentApp.swift             App entry point, shared URLCache budgets
├── ContentView.swift             Root: auth vs. main
├── Managers/
│   ├── SessionManager.swift      Auth state via sessionid cookie
│   ├── InstagramAPIBridge.swift  Hidden webview → private API reads
│   ├── WebActionBridge.swift     Hidden webview → real-UI writes
│   ├── RequestGovernor.swift     One shared cooldown + adaptive pacing
│   ├── ResponseCache.swift       Per-endpoint TTL cache, memory + disk
│   ├── FastDecode.swift          JSON → models; Swift and Rust backends
│   └── ImagePrefetcher.swift     Cache warming for the next page
├── Models/
│   ├── Post.swift                Domain models + IG DTOs + the reference mapping
│   ├── Direct.swift              Inbox/thread DTOs → DM models
│   └── Profile.swift             Profile info + user feed → grid
└── Views/
    ├── MainTabView.swift, FeedView.swift, StoriesView.swift,
    ├── StoryPlayerView.swift, MessagesView.swift, ProfileView.swift,
    ├── AuthenticationView.swift, ConstrainedInstagramWebView.swift,
    ├── SlowedDownBanner.swift
rust/filament-core/               Rust port of the mapping, C ABI, recorded cases
```

## Roadmap

- Run the Rust gate on a Mac (`cargo test`, `clippy`, `bench`, then shadow-diff
  both backends on real payloads) and ship the framework with the app.
- Move the decode off the main actor once the Rust path is the default.
- Native post detail and viewer (the grid and feed currently show media only).
- DM attachments and reactions; only text is rendered today.

## ⚠️ Disclaimer

Filament relies on Instagram's private, undocumented API and is not affiliated
with, endorsed by, or supported by Instagram or Meta. Use at your own risk —
Instagram's API and anti-automation measures may change at any time.

## License

GPL-3.0, inherited from [Strand](https://github.com/ericssonl07/instagram-strand).
See `LICENSE.txt`.
