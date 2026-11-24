//
//  FastDecode.swift
//  Filament
//
//  One place where Instagram's JSON becomes Filament's models.
//
//  The reference implementation is Models/Post.swift: decode IG's DTOs with
//  JSONDecoder, then map them (its `init?(raw:)`s). rust/filament-core ports
//  exactly that mapping to Rust and is reachable through the C ABI once
//  FilamentCore.xcframework is in the project — `canImport` picks it up on its
//  own. Without it, everything below falls back to the Swift path, so the app
//  always builds and behaves the same.
//

import Foundation

#if canImport(FilamentCore)
import FilamentCore
#endif

// MARK: - Swift reference implementation

/// The original mapping path, unchanged in behaviour: IG DTOs → domain models.
enum SwiftModelDecoder {

    static func timeline(from text: String) throws -> FeedPage {
        let resp = try decodeJSON(IGTimelineResponse.self, from: text)
        let posts = (resp.feedItems ?? [])
            .compactMap { $0.mediaOrAd }
            .compactMap(Post.init(raw:))
        return FeedPage(posts: posts,
                        nextMaxId: resp.nextMaxId,
                        moreAvailable: (resp.moreAvailable ?? false) && resp.nextMaxId != nil)
    }

    static func tray(from text: String) throws -> [Story] {
        let resp = try decodeJSON(IGReelsTrayResponse.self, from: text)
        return (resp.tray ?? []).compactMap(Story.init(raw:))
    }

    static func comments(from text: String) throws -> [Comment] {
        let resp = try decodeJSON(IGCommentsResponse.self, from: text)
        return (resp.comments ?? []).compactMap(Comment.init(raw:))
    }

    static func story(from text: String) throws -> [StoryItem] {
        let resp = try decodeJSON(IGUserStoryResponse.self, from: text)
        return (resp.reel?.items ?? []).compactMap(StoryItem.init(raw:))
    }

    static func currentUser(from text: String) throws -> User {
        let resp = try decodeJSON(IGCurrentUserResponse.self, from: text)
        guard let raw = resp.user else { throw BridgeError.badResponse }
        return User(raw: raw)
    }
}

// MARK: - Backend selection

/// The mapping entry point the bridge calls. Both backends answer to the same
/// signatures, so switching is a build setting — the framework being present —
/// rather than a code change.
enum ModelDecoder {

    static func timeline(from text: String) throws -> FeedPage {
        #if canImport(FilamentCore)
        return try RustModelDecoder.timeline(from: text)
        #else
        return try SwiftModelDecoder.timeline(from: text)
        #endif
    }

    static func tray(from text: String) throws -> [Story] {
        #if canImport(FilamentCore)
        return try RustModelDecoder.tray(from: text)
        #else
        return try SwiftModelDecoder.tray(from: text)
        #endif
    }

    static func comments(from text: String) throws -> [Comment] {
        #if canImport(FilamentCore)
        return try RustModelDecoder.comments(from: text)
        #else
        return try SwiftModelDecoder.comments(from: text)
        #endif
    }

    static func story(from text: String) throws -> [StoryItem] {
        #if canImport(FilamentCore)
        return try RustModelDecoder.story(from: text)
        #else
        return try SwiftModelDecoder.story(from: text)
        #endif
    }

    static func currentUser(from text: String) throws -> User {
        #if canImport(FilamentCore)
        return try RustModelDecoder.currentUser(from: text)
        #else
        return try SwiftModelDecoder.currentUser(from: text)
        #endif
    }
}

/// Decode `text` into `T`, turning an unexpected body into a diagnosable bridge
/// error instead of an opaque JSON error. Shared by every decoder in the app.
func decodeJSON<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
    guard let data = string.data(using: .utf8) else { throw BridgeError.badResponse }
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        throw BridgeError.httpStatus(0, "unexpected response: \(String(string.prefix(120)))")
    }
}

#if canImport(FilamentCore)

// MARK: - Rust backend

/// `rust/filament-core` through its C ABI: Rust parses IG's JSON, drops ads and
/// suggested posts, picks the image candidates, and hands back a flat document
/// that decodes in one cheap pass.
enum RustModelDecoder {

    static func timeline(from text: String) throws -> FeedPage {
        let flat = try decodeJSON(FlatFeedPage.self, from: mapping(text) {
            filament_map_timeline($0, $1)
        })
        return FeedPage(posts: flat.posts.compactMap { $0.model },
                        nextMaxId: flat.nextMaxId,
                        moreAvailable: flat.moreAvailable)
    }

    static func tray(from text: String) throws -> [Story] {
        let flat = try decodeJSON([FlatStory].self, from: mapping(text) {
            filament_map_tray($0, $1)
        })
        return flat.map { $0.model }
    }

    static func comments(from text: String) throws -> [Comment] {
        let flat = try decodeJSON([FlatComment].self, from: mapping(text) {
            filament_map_comments($0, $1)
        })
        return flat.map { $0.model }
    }

    static func story(from text: String) throws -> [StoryItem] {
        let flat = try decodeJSON([FlatStoryItem].self, from: mapping(text) {
            filament_map_story($0, $1)
        })
        return flat.compactMap { $0.model }
    }

    static func currentUser(from text: String) throws -> User {
        let flat = try decodeJSON(FlatUser.self, from: mapping(text) {
            filament_map_current_user($0, $1)
        })
        return flat.model
    }

    /// Run one Rust mapping call and copy its JSON back out (Rust owns the
    /// buffer and hands us the only pointer to it).
    private static func mapping(
        _ text: String,
        _ body: (UnsafePointer<UInt8>?, Int) -> UnsafeMutablePointer<CChar>?
    ) throws -> String {
        let bytes = Array(text.utf8)
        let result = bytes.withUnsafeBufferPointer {
            body($0.baseAddress, $0.count)
        }
        guard let result else { throw BridgeError.badResponse }
        defer { filament_free_string(result) }
        return String(cString: result)
    }
}

// MARK: - Flat documents emitted by Rust

private struct FlatUser: Decodable {
    let id: String
    let username: String
    let fullName: String
    let profilePicURL: String?
    let isVerified: Bool
}

private struct FlatPost: Decodable {
    let id: String
    let author: FlatUser
    let imageURLs: [String]
    let caption: String?
    let likeCount: Int
    let hasLiked: Bool
    let takenAt: Double
    let code: String?
}

private struct FlatFeedPage: Decodable {
    let posts: [FlatPost]
    let nextMaxId: String?
    let moreAvailable: Bool
}

private struct FlatStory: Decodable {
    let id: String
    let author: FlatUser
    let thumbnailURL: String?
    let hasUnseen: Bool
}

private struct FlatStoryItem: Decodable {
    let id: String
    let imageURL: String?
    let videoURL: String?
    let videoDuration: Double?
    let takenAt: Double
}

private struct FlatComment: Decodable {
    let id: String
    let user: FlatUser
    let text: String
    let createdAt: Double
}

// MARK: - Flat → domain models
//
// Rust already filtered what it could see; URL validity is decided here so the
// contract stays Swift's, exactly as `Post.init(raw:)` does it.

private extension FlatUser {
    var model: User {
        User(id: id,
             username: username,
             fullName: fullName,
             profilePicURL: profilePicURL.flatMap(URL.init(string:)),
             isVerified: isVerified)
    }
}

private extension FlatPost {
    var model: Post? {
        let urls = imageURLs.compactMap(URL.init(string:))
        guard !urls.isEmpty else { return nil }
        return Post(id: id,
                    author: author.model,
                    imageURLs: urls,
                    caption: caption,
                    likeCount: likeCount,
                    hasLiked: hasLiked,
                    takenAt: Date(timeIntervalSince1970: takenAt),
                    code: code)
    }
}

private extension FlatStory {
    var model: Story {
        Story(id: id,
              author: author.model,
              thumbnailURL: thumbnailURL.flatMap(URL.init(string:)),
              hasUnseen: hasUnseen)
    }
}

private extension FlatStoryItem {
    var model: StoryItem? {
        let image = imageURL.flatMap(URL.init(string:))
        let video = videoURL.flatMap(URL.init(string:))
        guard image != nil || video != nil else { return nil }
        return StoryItem(id: id,
                         imageURL: image,
                         videoURL: video,
                         videoDuration: videoDuration,
                         takenAt: Date(timeIntervalSince1970: takenAt))
    }
}

private extension FlatComment {
    var model: Comment {
        Comment(id: id,
                user: user.model,
                text: text,
                createdAt: Date(timeIntervalSince1970: createdAt))
    }
}

#endif
