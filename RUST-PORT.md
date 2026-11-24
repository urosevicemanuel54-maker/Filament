# The Rust port

`rust/filament-core` is the Rust port of the JSON → model mapping in
`Filament/Models/Post.swift`. This file records how it was chosen, how it is
checked, and what is still open.

## The skill, and why its CLI is not in the loop

The port follows the `rust-anything` method — profile → plan → bridge → record →
diff → bench → gate — but **its tooling cannot run on this project, or on this
device**:

- `rust-anything` ports TypeScript/JS, Python, C, Go, Ruby, Java, PHP and C#.
  This app is Swift, which it does not analyze or bridge.
- The CLI/MCP steps need `cargo` on a machine with a shell. There is no shell on
  this iPhone, so `analyze`, `bridge`, `record`, `diff`, `bench`, `gate` were all
  done by hand: units chosen by reading the code, recorded cases written as
  fixtures, and the gate's rules applied by inspection.

So the crate is a hand-built port with the same contract: units were chosen by
reading the code, and the recorded cases were written as fixtures. The cases
themselves are not taken on trust — they run in CI on every push (`cargo test`,
the `rust-core` job in `.github/workflows/ios-ipa.yml`). What still needs a Mac
is listed at the end.

## Plan: what is worth moving

| Unit | Where it runs | Called | Verdict |
|---|---|---|---|
| `Post.init(raw:)`, `Story.init(raw:)`, `StoryItem.init(raw:)`, `Comment.init(raw:)`, `User.init(raw:)` | every feed page, tray, story, comments load | once per item | **port** — one `JSONDecoder` walk of IG's large nested DTO tree plus mapping, per response |
| ad / suggested filtering (`injected`, `ad_id`) | inside the mapping | once per feed item | **port with the mapping** — free once the tree is parsed |
| image-candidate selection (`candidates.first`) | inside the mapping | once per post | **port with the mapping** |
| `mediaPK(_:)`, `formEncode(_:)` | per like / comment | once per action | keep in Swift — a call into Rust would cost more than the work |
| `pace()` jitter, `loadAndWait` timeouts | per request | once per request | keep in Swift — it is waiting, not computing |
| View bodies, `AsyncImage` | per frame | — | keep — UI code stays in the source language |

The mapping is the one genuinely hot, language-agnostic unit: it is the only
place where a large, variable-length payload (IG's timeline can be hundreds of
KB) is walked on the main actor before anything is drawn.

## The port

Rust parses IG's JSON once with `serde_json`, drops ads / suggested blocks /
posts with no id, user or image, picks the image candidates, and emits a **flat,
pre-filtered** document. Swift then decodes that — a far smaller payload — with
a plain `JSONDecoder`, and applies `URL(string:)` afterwards, so URL semantics
stay exactly the reference implementation's.

Exposed through a C ABI (`include/filament_core.h`):

```c
char *filament_map_timeline(const uint8_t *json, size_t len);
char *filament_map_tray(const uint8_t *json, size_t len);
char *filament_map_comments(const uint8_t *json, size_t len);
char *filament_map_story(const uint8_t *json, size_t len);
char *filament_map_current_user(const uint8_t *json, size_t len);
void  filament_free_string(char *s);
```

Swift side: `Filament/Managers/FastDecode.swift` holds both backends behind the
same signatures, and `ModelDecoder` picks one with `#if canImport(FilamentCore)`.
Without the framework the Swift path runs, so the app builds and behaves
identically today.

## Recorded cases

`rust/filament-core/tests/mapping.rs` is the characterization suite — the
`record` step, done by hand. Each test pins a rule the Swift implementation has:

- ads (`ad_id`) and suggested blocks (`injected`) are dropped;
- posts missing id, user, or any image are dropped; a carousel needs at least one
  usable image;
- carousels get one URL per item, single posts only the **first** candidate;
- flexible ids: string, integer, double truncated toward zero, anything else `""`;
- an absent `pk` falls back to `username`;
- `more_available` needs a `next_max_id` to be true;
- tray `has_unseen` is `latest_reel_media > seen`, defaulting both to 0;
- comments need both text and a user, `created_at` before `created_time`;
- story items need an image or a video;
- `current_user` without a user is an error;
- malformed JSON is an error, never a partial result.

## Known differences from the Swift path

Both are deliberate, and both only show up on data Instagram does not send:

1. Swift falls back to `UUID().uuidString` for a missing user `pk` **and**
   username (post author, comment id); the Rust port uses `""`. A random id
   cannot be reproduced across a C boundary, and a fresh UUID per call would
   make an unstable id a stable one.
2. Swift's `FlexibleString` traps (`Int(d)`) on a double too large for `Int`;
   Rust returns `""`.

## Gate

`cargo test` runs on every push in CI (`.github/workflows/ios-ipa.yml`, the
`rust-core` job) and passes: every recorded case above matches. Applied by
inspection, since the rest needs a full toolchain:

- no `unwrap` / `expect` / `panic!` in the mapping functions — every fallible
  path returns `Option` and the ABI turns `None` into a null pointer;
- `unsafe` only in the FFI boundary (`as_bytes`, `to_c_string`,
  `filament_free_string`), each with a `SAFETY:` comment;
- no `unimplemented!`, no placeholder paths;
- every rule the Swift implementation enforces has a recorded case above.

Not checked yet: `cargo fmt`, `clippy -D warnings`, `bench` (original vs Rust),
and the shadow diff below.

## On a Mac

```sh
cd rust/filament-core
cargo fmt
cargo clippy --all-targets -- -D warnings
cargo test                                   # the recorded cases
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
./build-ios.sh                               # → FilamentCore.xcframework
```

Then add `FilamentCore.xcframework` to the Filament target (Frameworks,
Libraries, and Embedded Content: **Do Not Embed**). `canImport(FilamentCore)`
becomes true and the app decodes through Rust; remove it and it is back on the
Swift path. Nothing else changes.

To compare the two backends on real payloads, capture a few response bodies from
`InstagramAPIBridge.callAPI` and assert `SwiftModelDecoder.x(from:)` equals
`RustModelDecoder.x(from:)` — the `shadow` step. It is not wired up because the
Rust side cannot be compiled here, so a shadow comparison would never have run.

## Next steps

- Run the gate above on a Mac; record real payloads and diff the two backends.
- Once the Rust path carries the default, the decode can move off the main actor
  (`Task.detached`): the Rust functions are pure and thread-safe, whereas the
  Swift DTOs are `MainActor`-isolated under this target's default isolation, so
  only the Rust path can make that move cheaply.

## Also done for speed (no Rust involved)

- `URLCache.shared` is given 64 MB memory / 512 MB disk at launch; the default
  512 KB is why re-scrolled photos downloaded again.
- `ImagePrefetcher` warms the cache for a newly loaded page (skipped on
  cellular and in Low Data Mode).
