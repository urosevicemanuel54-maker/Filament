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


// MARK: - web_profile_info
//
// The endpoint Instagram's own web client uses for a profile. One request
// returns the header counts AND the first page of the grid, where the older
// `/users/{pk}/info/` + `/feed/user/{pk}/` pair needs two and is now often
// refused outright.

struct ProfileSnapshot {
    let profile: UserProfile
    let page: ProfileFeedPage
}

struct IGWebProfileResponse: Decodable { let data: IGWebProfileData? }
struct IGWebProfileData: Decodable { let user: IGWebProfileUser? }

struct IGWebProfileUser: Decodable {
    let id: FlexibleString?
    let username: String?
    let fullName: String?
    let biography: String?
    let profilePicURL: String?
    let profilePicURLSmall: String?
    let isVerified: Bool?
    let isPrivate: Bool?
    let followers: IGCount?
    let following: IGCount?
    let media: IGWebMediaConnection?

    enum CodingKeys: String, CodingKey {
        case id, username, biography
        case fullName = "full_name"
        case profilePicURL = "profile_pic_url_hd"
        case profilePicURLSmall = "profile_pic_url"
        case isVerified = "is_verified"
        case isPrivate = "is_private"
        case followers = "edge_followed_by"
        case following = "edge_follow"
        case media = "edge_owner_to_timeline_media"
    }
}

struct IGCount: Decodable { let count: Int? }

struct IGWebMediaConnection: Decodable {
    let count: Int?
    let edges: [IGWebMediaEdge]?
}

struct IGWebMediaEdge: Decodable { let node: IGWebMediaNode? }

struct IGWebMediaNode: Decodable {
    let id: String?
    let shortcode: String?
    let displayURL: String?
    let isVideo: Bool?
    let takenAt: Double?
    let caption: IGWebCaption?
    let likes: IGCount?

    enum CodingKeys: String, CodingKey {
        case id, shortcode
        case displayURL = "display_url"
        case isVideo = "is_video"
        case takenAt = "taken_at_timestamp"
        case caption = "edge_media_to_caption"
        case likes = "edge_liked_by"
    }
}

struct IGWebCaption: Decodable { let edges: [IGWebCaptionEdge]? }
struct IGWebCaptionEdge: Decodable { let node: IGWebCaptionNode? }
struct IGWebCaptionNode: Decodable { let text: String? }

extension ProfileDecoder {

    /// Header counts + the first grid page from one `web_profile_info` body.
    ///
    /// The grid cursor this endpoint returns is GraphQL-shaped and is not valid
    /// for the `/feed/user/{pk}/?max_id=` endpoint, so paging stops after this
    /// page rather than guessing — a wrong cursor just burns a request on an
    /// endpoint that is already refusing us.
    static func snapshot(from text: String) throws -> ProfileSnapshot {
        let resp = try decodeJSON(IGWebProfileResponse.self, from: text)
        guard let raw = resp.data?.user else { throw BridgeError.badResponse }

        let profile = UserProfile(web: raw)
        let author = User(id: profile.id,
                          username: profile.username,
                          fullName: profile.fullName,
                          profilePicURL: profile.profilePicURL,
                          isVerified: profile.isVerified)
        let posts = (raw.media?.edges ?? [])
            .compactMap { $0.node }
            .compactMap { Post(web: $0, author: author) }

        return ProfileSnapshot(profile: profile,
                               page: ProfileFeedPage(posts: posts,
                                                     nextMaxId: nil,
                                                     moreAvailable: false))
    }
}

extension UserProfile {
    init(web raw: IGWebProfileUser) {
        self.id = raw.id?.value ?? ""
        self.username = raw.username ?? ""
        self.fullName = raw.fullName ?? ""
        self.biography = raw.biography ?? ""
        self.profilePicURL = (raw.profilePicURL ?? raw.profilePicURLSmall)
            .flatMap(URL.init(string:))
        self.isVerified = raw.isVerified ?? false
        self.isPrivate = raw.isPrivate ?? false
        self.postCount = raw.media?.count ?? 0
        self.followerCount = raw.followers?.count ?? 0
        self.followingCount = raw.following?.count ?? 0
    }
}

extension Post {
    /// `web_profile_info` grid nodes share no shape with `IGMedia`; the owner is
    /// only on the profile, so it is passed in.
    init?(web node: IGWebMediaNode, author: User) {
        guard let id = node.id,
              let urlString = node.displayURL,
              let url = URL(string: urlString) else { return nil }
        self.id = id
        self.author = author
        self.imageURLs = [url]
        self.caption = node.caption?.edges?.first?.node?.text
        self.likeCount = node.likes?.count ?? 0
        self.hasLiked = false
        self.takenAt = Date(timeIntervalSince1970: node.takenAt ?? 0)
        self.code = node.shortcode
    }
}
