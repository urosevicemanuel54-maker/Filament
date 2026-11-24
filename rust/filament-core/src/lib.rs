//! Filament core: the Rust port of `Filament/Models/Post.swift`.
//!
//! The Swift file stays the reference implementation. This crate performs the
//! same work — parse Instagram's private JSON, drop ads / suggested blocks /
//! unusable posts, pick the image candidates — and emits a *flat, pre-filtered*
//! document holding only the fields the UI needs, so Swift decodes it in one
//! cheap pass instead of walking Instagram's whole nested DTO tree.
//!
//! Behaviour is pinned to the Swift implementation by `tests/mapping.rs`; those
//! tests are this port's recorded cases.
//!
//! Exposed through a small C ABI (`Filament/include/filament_core.h`). `URL`
//! validity is deliberately *not* decided here: Rust emits the candidate strings
//! and Swift runs them through `URL(string:)`, so URL semantics stay identical
//! to the reference implementation.

use serde::{Deserialize, Deserializer, Serialize};
use std::ffi::{c_char, CString};

// MARK: - Input DTOs (the subset Post.swift decodes)

/// IG sends some IDs as numbers and others as strings, exactly like
/// `FlexibleString` in the Swift model: a string as-is, an integer in decimal,
/// a double truncated toward zero, anything else empty.
enum Flexible {
    Str(String),
    Int(i64),
    Float(f64),
    Other,
}

impl<'de> Deserialize<'de> for Flexible {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = serde_json::Value::deserialize(deserializer)?;
        Ok(match value {
            serde_json::Value::String(s) => Flexible::Str(s),
            serde_json::Value::Number(n) => match n.as_i64() {
                Some(i) => Flexible::Int(i),
                None => match n.as_f64() {
                    Some(f) => Flexible::Float(f),
                    None => Flexible::Other,
                },
            },
            _ => Flexible::Other,
        })
    }
}

impl Flexible {
    /// `FlexibleString.value` in Swift.
    fn as_text(&self) -> String {
        match self {
            Flexible::Str(s) => s.clone(),
            Flexible::Int(i) => i.to_string(),
            Flexible::Float(f) => {
                if f.is_finite() {
                    // Swift: String(Int(d)) — truncation toward zero. Swift would
                    // trap on a value Int cannot hold; we return "" instead.
                    (*f as i64).to_string()
                } else {
                    String::new()
                }
            }
            Flexible::Other => String::new(),
        }
    }
}

#[derive(Deserialize)]
struct UserDto {
    pk: Option<Flexible>,
    username: Option<String>,
    full_name: Option<String>,
    profile_pic_url: Option<String>,
    is_verified: Option<bool>,
}

#[derive(Deserialize)]
struct Caption {
    text: Option<String>,
}

#[derive(Deserialize)]
struct Candidate {
    url: Option<String>,
}

#[derive(Deserialize)]
struct ImageVersions {
    candidates: Option<Vec<Candidate>>,
}

#[derive(Deserialize)]
struct CarouselItem {
    image_versions2: Option<ImageVersions>,
}

/// Empty: only the presence of the key matters (ads / suggested blocks).
#[derive(Deserialize)]
struct Injected {}

#[derive(Deserialize)]
struct Media {
    id: Option<String>,
    code: Option<String>,
    taken_at: Option<f64>,
    user: Option<UserDto>,
    caption: Option<Caption>,
    like_count: Option<i64>,
    has_liked: Option<bool>,
    image_versions2: Option<ImageVersions>,
    carousel_media: Option<Vec<CarouselItem>>,
    injected: Option<Injected>,
    ad_id: Option<String>,
}

#[derive(Deserialize)]
struct FeedItem {
    media_or_ad: Option<Media>,
}

#[derive(Deserialize)]
struct TimelineResponse {
    feed_items: Option<Vec<FeedItem>>,
    next_max_id: Option<String>,
    more_available: Option<bool>,
}

#[derive(Deserialize)]
struct TrayReel {
    id: Option<Flexible>,
    user: Option<UserDto>,
    seen: Option<f64>,
    latest_reel_media: Option<f64>,
}

#[derive(Deserialize)]
struct TrayResponse {
    tray: Option<Vec<TrayReel>>,
}

#[derive(Deserialize)]
struct CurrentUserResponse {
    user: Option<UserDto>,
}

#[derive(Deserialize)]
struct CommentDto {
    pk: Option<Flexible>,
    text: Option<String>,
    user: Option<UserDto>,
    created_at: Option<f64>,
    created_time: Option<f64>,
}

#[derive(Deserialize)]
struct CommentsResponse {
    comments: Option<Vec<CommentDto>>,
}

#[derive(Deserialize)]
struct VideoVersion {
    url: Option<String>,
}

#[derive(Deserialize)]
struct StoryItemDto {
    pk: Option<Flexible>,
    id: Option<String>,
    taken_at: Option<f64>,
    image_versions2: Option<ImageVersions>,
    video_versions: Option<Vec<VideoVersion>>,
    video_duration: Option<f64>,
}

#[derive(Deserialize)]
struct Reel {
    items: Option<Vec<StoryItemDto>>,
}

#[derive(Deserialize)]
struct UserStoryResponse {
    reel: Option<Reel>,
}

// MARK: - Output (flat, camelCase, JSON-encoded)

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OutUser {
    id: String,
    username: String,
    full_name: String,
    #[serde(rename = "profilePicURL")]
    profile_pic_url: Option<String>,
    is_verified: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OutPost {
    id: String,
    author: OutUser,
    #[serde(rename = "imageURLs")]
    image_urls: Vec<String>,
    caption: Option<String>,
    like_count: i64,
    has_liked: bool,
    taken_at: f64,
    code: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OutFeedPage {
    posts: Vec<OutPost>,
    next_max_id: Option<String>,
    more_available: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OutStory {
    id: String,
    author: OutUser,
    #[serde(rename = "thumbnailURL")]
    thumbnail_url: Option<String>,
    has_unseen: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OutStoryItem {
    id: String,
    #[serde(rename = "imageURL")]
    image_url: Option<String>,
    #[serde(rename = "videoURL")]
    video_url: Option<String>,
    video_duration: Option<f64>,
    taken_at: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OutComment {
    id: String,
    user: OutUser,
    text: String,
    created_at: f64,
}

// MARK: - Mapping

fn map_user(raw: &UserDto) -> OutUser {
    OutUser {
        // Swift: pk?.value ?? username ?? UUID().uuidString. There is no UUID
        // here; an absent pk *and* username becomes "" rather than a random id.
        id: raw
            .pk
            .as_ref()
            .map(Flexible::as_text)
            .or_else(|| raw.username.clone())
            .unwrap_or_default(),
        username: raw
            .username
            .clone()
            .unwrap_or_else(|| "unknown".to_string()),
        full_name: raw.full_name.clone().unwrap_or_default(),
        profile_pic_url: raw.profile_pic_url.clone(),
        is_verified: raw.is_verified.unwrap_or(false),
    }
}

/// Only the first candidate of an image set is considered, like the Swift
/// `candidates?.first?.url`.
fn first_url(versions: Option<&ImageVersions>) -> Option<String> {
    versions?.candidates.as_ref()?.first()?.url.clone()
}

fn map_post(raw: &Media) -> Option<OutPost> {
    if raw.injected.is_some() || raw.ad_id.is_some() {
        return None;
    }
    let id = raw.id.clone()?;
    let user = raw.user.as_ref()?;

    let mut image_urls: Vec<String> = Vec::new();
    match raw.carousel_media.as_ref() {
        Some(items) if !items.is_empty() => {
            for item in items {
                if let Some(url) = first_url(item.image_versions2.as_ref()) {
                    image_urls.push(url);
                }
            }
        }
        _ => {
            if let Some(url) = first_url(raw.image_versions2.as_ref()) {
                image_urls.push(url);
            }
        }
    }
    if image_urls.is_empty() {
        return None;
    }

    Some(OutPost {
        id,
        author: map_user(user),
        image_urls,
        caption: raw.caption.as_ref().and_then(|c| c.text.clone()),
        like_count: raw.like_count.unwrap_or(0),
        has_liked: raw.has_liked.unwrap_or(false),
        taken_at: raw.taken_at.unwrap_or(0.0),
        code: raw.code.clone(),
    })
}

fn map_story(raw: &TrayReel) -> Option<OutStory> {
    let user = raw.user.as_ref()?;
    let author = map_user(user);
    Some(OutStory {
        id: raw
            .id
            .as_ref()
            .map(Flexible::as_text)
            .unwrap_or_else(|| author.id.clone()),
        thumbnail_url: author.profile_pic_url.clone(),
        has_unseen: raw.latest_reel_media.unwrap_or(0.0) > raw.seen.unwrap_or(0.0),
        author,
    })
}

fn map_story_item(raw: &StoryItemDto) -> Option<OutStoryItem> {
    let id = raw
        .pk
        .as_ref()
        .map(Flexible::as_text)
        .or_else(|| raw.id.clone())?;
    let image_url = raw
        .image_versions2
        .as_ref()
        .and_then(|v| v.candidates.as_ref())
        .and_then(|c| c.first())
        .and_then(|c| c.url.clone());
    let video_url = raw
        .video_versions
        .as_ref()
        .and_then(|v| v.first())
        .and_then(|v| v.url.clone());
    if image_url.is_none() && video_url.is_none() {
        return None;
    }
    Some(OutStoryItem {
        id,
        image_url,
        video_url,
        video_duration: raw.video_duration,
        taken_at: raw.taken_at.unwrap_or(0.0),
    })
}

fn map_comment(raw: &CommentDto) -> Option<OutComment> {
    let text = raw.text.clone()?;
    let user = raw.user.as_ref()?;
    Some(OutComment {
        // Swift falls back to a random UUID here; see map_user.
        id: raw
            .pk
            .as_ref()
            .map(Flexible::as_text)
            .unwrap_or_default(),
        user: map_user(user),
        text,
        created_at: raw.created_at.or(raw.created_time).unwrap_or(0.0),
    })
}

fn to_json<T: Serialize>(value: &T) -> Option<String> {
    serde_json::to_string(value).ok()
}

fn from_json<T: for<'de> Deserialize<'de>>(json: &[u8]) -> Option<T> {
    serde_json::from_slice(json).ok()
}

// MARK: - Public API

/// Feed page: posts, cursor, and whether another page exists.
pub fn map_timeline(json: &[u8]) -> Option<String> {
    let resp: TimelineResponse = from_json(json)?;
    let mut posts = Vec::new();
    if let Some(items) = resp.feed_items.as_ref() {
        for item in items {
            if let Some(media) = item.media_or_ad.as_ref() {
                if let Some(post) = map_post(media) {
                    posts.push(post);
                }
            }
        }
    }
    let more_available =
        resp.more_available.unwrap_or(false) && resp.next_max_id.is_some();
    to_json(&OutFeedPage {
        posts,
        next_max_id: resp.next_max_id,
        more_available,
    })
}

/// Stories tray.
pub fn map_tray(json: &[u8]) -> Option<String> {
    let resp: TrayResponse = from_json(json)?;
    let stories: Vec<OutStory> = resp
        .tray
        .as_ref()
        .map(|tray| tray.iter().filter_map(map_story).collect())
        .unwrap_or_default();
    to_json(&stories)
}

/// A post's comments.
pub fn map_comments(json: &[u8]) -> Option<String> {
    let resp: CommentsResponse = from_json(json)?;
    let comments: Vec<OutComment> = resp
        .comments
        .as_ref()
        .map(|list| list.iter().filter_map(map_comment).collect())
        .unwrap_or_default();
    to_json(&comments)
}

/// One user's story items.
pub fn map_story(json: &[u8]) -> Option<String> {
    let resp: UserStoryResponse = from_json(json)?;
    let items: Vec<OutStoryItem> = resp
        .reel
        .as_ref()
        .and_then(|reel| reel.items.as_ref())
        .map(|list| list.iter().filter_map(map_story_item).collect())
        .unwrap_or_default();
    to_json(&items)
}

/// The logged-in user. `None` when the response carries no user (Swift throws
/// `badResponse` there).
pub fn map_current_user(json: &[u8]) -> Option<String> {
    let resp: CurrentUserResponse = from_json(json)?;
    to_json(&map_user(resp.user.as_ref()?))
}

// MARK: - C ABI

/// # Safety
/// `ptr` must point to at least `len` initialized bytes, or be null.
unsafe fn as_bytes<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if ptr.is_null() || len == 0 {
        return None;
    }
    // SAFETY: the caller guarantees ptr/len describe a live buffer.
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

fn to_c_string(json: Option<String>) -> *mut c_char {
    let Some(json) = json else {
        return std::ptr::null_mut();
    };
    // A NUL byte cannot travel through a C string: drop it instead of failing
    // the whole call.
    match CString::new(json.replace('\0', "")) {
        Ok(c) => c.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

macro_rules! ffi_map {
    ($name:ident, $mapping:ident) => {
        #[no_mangle]
        pub extern "C" fn $name(json: *const u8, len: usize) -> *mut c_char {
            // SAFETY: handed straight through to `as_bytes`, which validates
            // null and zero length; the caller owns the buffer.
            let input = unsafe { as_bytes(json, len) };
            to_c_string(input.and_then($mapping))
        }
    };
}

ffi_map!(filament_map_timeline, map_timeline);
ffi_map!(filament_map_tray, map_tray);
ffi_map!(filament_map_comments, map_comments);
ffi_map!(filament_map_story, map_story);
ffi_map!(filament_map_current_user, map_current_user);

/// # Safety
/// `s` must be a pointer returned by one of this crate's `filament_map_*`
/// functions, or null, and must not be used again afterwards.
#[no_mangle]
pub unsafe extern "C" fn filament_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    // SAFETY: produced by CString::into_raw in to_c_string.
    drop(unsafe { CString::from_raw(s) });
}
