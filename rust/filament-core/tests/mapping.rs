//! Recorded cases for the Rust port: the behaviour `Models/Post.swift` defines,
//! checked against this crate's mapping. Each fixture is an Instagram-shaped
//! response; each assertion is a rule the Swift reference implementation has.

use filament_core::{map_comments, map_current_user, map_story, map_timeline, map_tray};
use serde_json::Value;

fn parse(mapped: Option<String>) -> Value {
    let text = mapped.expect("mapping returned None");
    serde_json::from_str(&text).expect("mapping produced invalid JSON")
}

const TIMELINE: &str = r#"{
  "feed_items": [
    {"media_or_ad": {
      "id": "111_222",
      "code": "CxYz",
      "taken_at": 1700000000.0,
      "user": {"pk": 42, "username": "alice", "full_name": "Alice",
               "profile_pic_url": "https://cdn/x.jpg", "is_verified": true},
      "caption": {"text": "hello"},
      "like_count": 7,
      "has_liked": true,
      "image_versions2": {"candidates": [{"url": "https://cdn/a.jpg", "width": 1080},
                                        {"url": "https://cdn/b.jpg"}]}
    }},
    {"media_or_ad": {
      "id": "333_444",
      "taken_at": 1700000100.0,
      "user": {"pk": "333", "username": "carol"},
      "carousel_media": [
        {"image_versions2": {"candidates": [{"url": "https://cdn/c1.jpg"}]}},
        {"image_versions2": {"candidates": [{"url": "https://cdn/c2.jpg"}]}}
      ]
    }},
    {"media_or_ad": {"id": "555", "ad_id": "ad-1", "user": {"pk": "555"},
      "image_versions2": {"candidates": [{"url": "https://cdn/ad.jpg"}]}}},
    {"media_or_ad": {"id": "666", "injected": {}, "user": {"pk": "666"},
      "image_versions2": {"candidates": [{"url": "https://cdn/sug.jpg"}]}}},
    {"media_or_ad": {"user": {"pk": "777"},
      "image_versions2": {"candidates": [{"url": "https://cdn/noid.jpg"}]}}},
    {"media_or_ad": {"id": "888",
      "image_versions2": {"candidates": [{"url": "https://cdn/nouser.jpg"}]}}},
    {"media_or_ad": {"id": "999", "user": {"pk": "999"}}},
    {"is_suggested": true}
  ],
  "next_max_id": "cursor-1",
  "more_available": true
}"#;

#[test]
fn timeline_keeps_only_renderable_posts() {
    let page = parse(map_timeline(TIMELINE.as_bytes()));
    let posts = page["posts"].as_array().expect("posts array");
    assert_eq!(posts.len(), 2, "ads, suggested blocks and empty posts are dropped");

    assert_eq!(posts[0]["id"], "111_222");
    assert_eq!(posts[0]["imageURLs"], serde_json::json!(["https://cdn/a.jpg"]));
    assert_eq!(posts[0]["caption"], "hello");
    assert_eq!(posts[0]["likeCount"], 7);
    assert_eq!(posts[0]["hasLiked"], true);
    assert_eq!(posts[0]["takenAt"], 1700000000.0);
    assert_eq!(posts[0]["code"], "CxYz");

    // Numeric pk, as IG sometimes sends it.
    assert_eq!(posts[0]["author"]["id"], "42");
    assert_eq!(posts[0]["author"]["username"], "alice");
    assert_eq!(posts[0]["author"]["fullName"], "Alice");
    assert_eq!(posts[0]["author"]["profilePicURL"], "https://cdn/x.jpg");
    assert_eq!(posts[0]["author"]["isVerified"], true);

    // Carousel: one URL per item, first candidate only.
    assert_eq!(
        posts[1]["imageURLs"],
        serde_json::json!(["https://cdn/c1.jpg", "https://cdn/c2.jpg"])
    );
    assert_eq!(posts[1]["caption"], Value::Null);
    assert_eq!(posts[1]["likeCount"], 0);
    assert_eq!(posts[1]["hasLiked"], false);
    // pk as a string.
    assert_eq!(posts[1]["author"]["id"], "333");
    assert_eq!(posts[1]["author"]["fullName"], "");
    assert_eq!(posts[1]["author"]["profilePicURL"], Value::Null);
    assert_eq!(posts[1]["author"]["isVerified"], false);

    assert_eq!(page["nextMaxId"], "cursor-1");
    assert_eq!(page["moreAvailable"], true);
}

#[test]
fn more_available_needs_a_cursor() {
    let body = r#"{"feed_items": [], "more_available": true}"#;
    let page = parse(map_timeline(body.as_bytes()));
    assert_eq!(page["moreAvailable"], false);
    assert_eq!(page["nextMaxId"], Value::Null);
    assert_eq!(page["posts"].as_array().map(Vec::len), Some(0));
}

#[test]
fn timeline_that_is_not_json_fails() {
    assert!(map_timeline(b"not json").is_none());
    assert!(map_timeline(b"").is_none());
}

#[test]
fn tray_unseen_and_thumbnail() {
    let body = r#"{"tray": [
      {"id": 10, "user": {"pk": 1, "username": "a", "profile_pic_url": "https://cdn/p.jpg"},
       "seen": 100.0, "latest_reel_media": 200.0},
      {"id": "11", "user": {"pk": 2, "username": "b"}, "seen": 200.0, "latest_reel_media": 200.0},
      {"id": "12", "user": {"pk": 3, "username": "c"}},
      {"id": "13"}
    ]}"#;
    let stories = parse(map_tray(body.as_bytes()));
    let stories = stories.as_array().expect("stories array");
    assert_eq!(stories.len(), 3, "a reel without a user is dropped");

    assert_eq!(stories[0]["id"], "10");
    assert_eq!(stories[0]["hasUnseen"], true);
    assert_eq!(stories[0]["thumbnailURL"], "https://cdn/p.jpg");
    assert_eq!(stories[0]["author"]["id"], "1");

    assert_eq!(stories[1]["hasUnseen"], false);
    assert_eq!(stories[1]["thumbnailURL"], Value::Null);

    // No latest_reel_media and no seen: 0 > 0 is false.
    assert_eq!(stories[2]["hasUnseen"], false);
    assert_eq!(stories[2]["id"], "12");
}

#[test]
fn comments_need_text_and_a_user() {
    let body = r#"{"comments": [
      {"pk": 1, "text": "first", "user": {"pk": 9, "username": "u"}, "created_at": 100.0},
      {"pk": "2", "text": "second", "user": {"pk": 9, "username": "u"}, "created_time": 200.0},
      {"pk": "3", "user": {"pk": 9, "username": "u"}},
      {"pk": "4", "text": "orphan"}
    ]}"#;
    let comments = parse(map_comments(body.as_bytes()));
    let comments = comments.as_array().expect("comments array");
    assert_eq!(comments.len(), 2);
    assert_eq!(comments[0]["id"], "1");
    assert_eq!(comments[0]["text"], "first");
    assert_eq!(comments[0]["createdAt"], 100.0);
    // created_time is the fallback.
    assert_eq!(comments[1]["id"], "2");
    assert_eq!(comments[1]["createdAt"], 200.0);
}

#[test]
fn story_items_need_media() {
    let body = r#"{"reel": {"items": [
      {"pk": 1, "taken_at": 10.0,
       "image_versions2": {"candidates": [{"url": "https://cdn/i.jpg"}]}},
      {"id": "vid", "taken_at": 20.0,
       "video_versions": [{"url": "https://cdn/v.mp4"}], "video_duration": 12.5},
      {"pk": "3"},
      {"pk": "4", "image_versions2": {"candidates": []}}
    ]}}"#;
    let items = parse(map_story(body.as_bytes()));
    let items = items.as_array().expect("items array");
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["id"], "1");
    assert_eq!(items[0]["imageURL"], "https://cdn/i.jpg");
    assert_eq!(items[0]["videoURL"], Value::Null);
    assert_eq!(items[0]["videoDuration"], Value::Null);
    assert_eq!(items[1]["id"], "vid");
    assert_eq!(items[1]["imageURL"], Value::Null);
    assert_eq!(items[1]["videoURL"], "https://cdn/v.mp4");
    assert_eq!(items[1]["videoDuration"], 12.5);
    assert_eq!(items[1]["takenAt"], 20.0);
}

#[test]
fn current_user_requires_a_user() {
    assert!(map_current_user(br#"{"user": null}"#).is_none());
    assert!(map_current_user(br#"{}"#).is_none());

    let user = parse(map_current_user(br#"{"user": {"pk": 5, "username": "me"}}"#));
    assert_eq!(user["id"], "5");
    assert_eq!(user["username"], "me");
    assert_eq!(user["fullName"], "");
    assert_eq!(user["isVerified"], false);
}

#[test]
fn numeric_ids_truncate_toward_zero() {
    let user = parse(map_current_user(br#"{"user": {"pk": 1.9, "username": "x"}}"#));
    assert_eq!(user["id"], "1");
}

#[test]
fn absent_pk_falls_back_to_username() {
    let user = parse(map_current_user(br#"{"user": {"username": "only"}}"#));
    assert_eq!(user["id"], "only");
    assert_eq!(user["username"], "only");
}
