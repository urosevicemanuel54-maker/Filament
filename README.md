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
- **Writes** (likes, comments) drive Instagram's real UI in a second hidden
  webview — clicking the actual button, typing into the actual box — because raw
  write calls lack the integrity tokens Instagram expects.
- **Login, DMs and your own profile** use a path-locked, visible `WKWebView`
  showing Instagram's genuine UI, restricted by a JS sentry to the routes it is
  meant for.

## Features

| Area | Status | Notes |
|---|---|---|
| Feed | Native | Chronological, cursor-paginated, like/comment/share, no ranking or injected ads. |
| Stories | Native | Tray + fullscreen player: progress bars, tap-to-advance, hold-to-pause, swipe-to-dismiss, video via AVKit. |
| Comments | Native, read | Reading works; posting goes through the web-UI bridge and still needs work, as upstream. |
| Messages | Functional | Constrained webview onto Instagram's real DM UI. |
| Profile | To be implemented | Constrained webview + native logout. |
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
│   ├── FastDecode.swift          JSON → models; Swift and Rust backends
│   └── ImagePrefetcher.swift     Cache warming for the next page
├── Models/
│   └── Post.swift                Domain models + IG DTOs + the reference mapping
└── Views/
    ├── MainTabView.swift, FeedView.swift, StoriesView.swift,
    ├── StoryPlayerView.swift, MessagesView.swift, ProfileView.swift,
    ├── AuthenticationView.swift, ConstrainedInstagramWebView.swift
rust/filament-core/               Rust port of the mapping, C ABI, recorded cases
```

## Roadmap

- Run the Rust gate on a Mac (`cargo test`, `clippy`, `bench`, then shadow-diff
  both backends on real payloads) and ship the framework with the app.
- Move the decode off the main actor once the Rust path is the default.
- Fix comment posting and the profile view (both inherited from upstream).
- Native DM interface.

## ⚠️ Disclaimer

Filament relies on Instagram's private, undocumented API and is not affiliated
with, endorsed by, or supported by Instagram or Meta. Use at your own risk —
Instagram's API and anti-automation measures may change at any time.

## License

GPL-3.0, inherited from [Strand](https://github.com/ericssonl07/instagram-strand).
See `LICENSE.txt`.
