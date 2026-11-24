//
//  Profile.swift
//  Filament
//
//  The logged-in user's profile from Instagram's private API: header counts
//  plus the first page of their media grid.
//

import Foundation

// MARK: - Domain models

struct UserProfile: Identifiable, Hashable {
    let id: String
    let username: String
    let fullName: String
    let biography: String
    let profilePicURL: URL?
    let isVerified: Bool
    let isPrivate: Bool
    let postCount: Int
    let followerCount: Int
    let followingCount: Int
}

struct ProfileFeedPage {
    let posts: [Post]
    let nextMaxId: String?
    let moreAvailable: Bool
}

// MARK: - DTOs

struct IGProfileResponse: Decodable { let user: IGProfileUser? }

struct IGProfileUser: Decodable {
    let pk: FlexibleString?
    let username: String?
    let fullName: String?
    let biography: String?
    let profilePicURL: String?
    let isVerified: Bool?
    let isPrivate: Bool?
    let mediaCount: Int?
    let followerCount: Int?
    let followingCount: Int?

    enum CodingKeys: String, CodingKey {
        case pk, username, biography
        case fullName = "full_name"
        case profilePicURL = "profile_pic_url"
        case isVerified = "is_verified"
        case isPrivate = "is_private"
        case mediaCount = "media_count"
        case followerCount = "follower_count"
        case followingCount = "following_count"
    }
}

/// `/api/v1/feed/user/{pk}/` returns raw media objects — the same shape the
/// timeline nests under `feed_items[].media_or_ad`.
struct IGUserFeedResponse: Decodable {
    let items: [IGMedia]?
    let nextMaxId: String?
    let moreAvailable: Bool?

    enum CodingKeys: String, CodingKey {
        case items
        case nextMaxId = "next_max_id"
        case moreAvailable = "more_available"
    }
}

// MARK: - Decoding

enum ProfileDecoder {

    static func profile(from text: String) throws -> UserProfile {
        let resp = try decodeJSON(IGProfileResponse.self, from: text)
        guard let raw = resp.user else { throw BridgeError.badResponse }
        return UserProfile(raw: raw)
    }

    static func feed(from text: String) throws -> ProfileFeedPage {
        let resp = try decodeJSON(IGUserFeedResponse.self, from: text)
        let posts = (resp.items ?? []).compactMap(Post.init(raw:))
        return ProfileFeedPage(posts: posts,
                               nextMaxId: resp.nextMaxId,
                               moreAvailable: (resp.moreAvailable ?? false) && resp.nextMaxId != nil)
    }
}

// MARK: - Raw → domain mapping

extension UserProfile {
    init(raw: IGProfileUser) {
        self.id = raw.pk?.value ?? ""
        self.username = raw.username ?? ""
        self.fullName = raw.fullName ?? ""
        self.biography = raw.biography ?? ""
        self.profilePicURL = raw.profilePicURL.flatMap(URL.init(string:))
        self.isVerified = raw.isVerified ?? false
        self.isPrivate = raw.isPrivate ?? false
        self.postCount = raw.mediaCount ?? 0
        self.followerCount = raw.followerCount ?? 0
        self.followingCount = raw.followingCount ?? 0
    }
}
