//
//  Direct.swift
//  Filament
//
//  Native direct messages from Instagram's private direct_v2 API:
//  inbox → threads, thread → messages, and sending text.
//

import Foundation

// MARK: - Domain models

struct DirectThread: Identifiable, Hashable {
    let id: String
    let title: String
    let avatarURL: URL?
    let preview: String
    let lastActivity: Date
    let isUnseen: Bool
}

struct DirectMessage: Identifiable, Hashable {
    let id: String
    let text: String
    let isFromMe: Bool
    let sender: String
    let avatarURL: URL?
    let sentAt: Date
}

/// What a thread view needs: who it is, and the conversation oldest-first.
struct DirectThreadContent {
    let title: String
    let avatarURL: URL?
    let messages: [DirectMessage]
}

// MARK: - DTOs

struct IGInboxResponse: Decodable { let inbox: IGInbox? }
struct IGInbox: Decodable { let threads: [IGDirectThread]? }

struct IGDirectThread: Decodable {
    let threadID: FlexibleString?
    let threadTitle: String?
    let users: [IGDirectUser]?
    let items: [IGDirectItem]?
    let lastActivityAt: FlexibleString?
    let readState: Int?

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case threadTitle = "thread_title"
        case users, items
        case lastActivityAt = "last_activity_at"
        case readState = "read_state"
    }
}

struct IGThreadResponse: Decodable { let thread: IGDirectThread? }

struct IGDirectUser: Decodable {
    let pk: FlexibleString?
    let username: String?
    let fullName: String?
    let profilePicURL: String?

    enum CodingKeys: String, CodingKey {
        case pk, username
        case fullName = "full_name"
        case profilePicURL = "profile_pic_url"
    }
}

struct IGDirectItem: Decodable {
    let itemID: FlexibleString?
    let userID: FlexibleString?
    let timestamp: FlexibleString?
    let itemType: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case userID = "user_id"
        case timestamp
        case itemType = "item_type"
        case text
    }
}

// MARK: - Decoding

enum DirectDecoder {

    static func threads(from text: String, meID: String) throws -> [DirectThread] {
        let resp = try decodeJSON(IGInboxResponse.self, from: text)
        return (resp.inbox?.threads ?? []).compactMap {
            DirectThread(raw: $0, meID: meID)
        }
    }

    static func content(from text: String, meID: String) throws -> DirectThreadContent {
        let resp = try decodeJSON(IGThreadResponse.self, from: text)
        guard let raw = resp.thread else { throw BridgeError.badResponse }
        let users = raw.users ?? []
        let items = raw.items ?? []
        // direct_v2 returns newest first; a thread reads oldest first.
        let messages = items
            .compactMap { DirectMessage(raw: $0, meID: meID, users: users) }
            .reversed()
        return DirectThreadContent(title: resolvedTitle(raw: raw, meID: meID),
                                   avatarURL: resolvedAvatarURL(raw: raw, meID: meID),
                                   messages: Array(messages))
    }
}

// MARK: - Raw → domain mapping

extension DirectThread {
    init?(raw: IGDirectThread, meID: String) {
        guard let id = raw.threadID?.value, !id.isEmpty else { return nil }

        let last = raw.items?.first
        let lastFromOther = last?.userID?.value != meID
        let preview = last.flatMap(DirectMessage.body(for:)) ?? ""
        let isMine = last.map { $0.userID?.value == meID } ?? false

        self.id = id
        self.title = resolvedTitle(raw: raw, meID: meID)
        self.avatarURL = resolvedAvatarURL(raw: raw, meID: meID)
        self.preview = isMine && !preview.isEmpty ? "You: \(preview)" : preview
        self.lastActivity = igDate(raw.lastActivityAt)
        // read_state 0 means unread; require the last word to be theirs so a
        // thread we just answered does not stay flagged.
        self.isUnseen = (raw.readState ?? 1) == 0 && lastFromOther
    }
}

extension DirectMessage {
    init?(raw: IGDirectItem, meID: String, users: [IGDirectUser]) {
        guard let id = raw.itemID?.value, let text = DirectMessage.body(for: raw) else {
            return nil
        }

        let authorID = raw.userID?.value ?? ""
        let author = users.first { ($0.pk?.value ?? "") == authorID }
        let fromMe = !meID.isEmpty && authorID == meID

        self.id = id
        self.text = text
        self.isFromMe = fromMe
        self.sender = author?.username ?? (fromMe ? "You" : "")
        self.avatarURL = author?.profilePicURL.flatMap(URL.init(string:))
        self.sentAt = igDate(raw.timestamp)
    }

    /// Text to show for an item. Media items become a short stand-in, so a
    /// conversation reads sensibly even though only text is rendered.
    static func body(for item: IGDirectItem) -> String? {
        if let text = item.text, !text.isEmpty { return text }

        switch item.itemType {
        case "media", "raven_media":   return "Sent a photo"
        case "video":                  return "Sent a video"
        case "clip":                   return "Sent a reel"
        case "animated_media", "felix_share": return "Sent a GIF"
        case "voice_media":            return "Voice message"
        case "like":                   return "Liked a message"
        case "media_share":            return "Shared a post"
        case "story_share":            return "Shared a story"
        case "link":                   return "Shared a link"
        case "profile":                return "Shared a profile"
        case "placeholder":            return nil
        case nil:                      return nil
        default:                       return "Sent an attachment"
        }
    }
}

// MARK: - Helpers

private func author(_ raw: IGDirectThread, meID: String) -> IGDirectUser? {
    let users = raw.users ?? []
    return users.first { ($0.pk?.value ?? "") != meID } ?? users.first
}

private func resolvedTitle(raw: IGDirectThread, meID: String) -> String {
    if let title = raw.threadTitle, !title.isEmpty { return title }
    let other = author(raw, meID: meID)
    if let fullName = other?.fullName, !fullName.isEmpty { return fullName }
    return other?.username ?? "Thread"
}

private func resolvedAvatarURL(raw: IGDirectThread, meID: String) -> URL? {
    author(raw, meID: meID)?.profilePicURL.flatMap(URL.init(string:))
}

/// Direct timestamps arrive in microseconds; older shapes use milliseconds or
/// seconds, so pick the unit from the magnitude.
private func igDate(_ raw: FlexibleString?) -> Date {
    guard let raw, let value = Double(raw.value), value > 0 else {
        return Date(timeIntervalSince1970: 0)
    }
    let seconds: Double
    if value > 1e14 {
        seconds = value / 1_000_000
    } else if value > 1e11 {
        seconds = value / 1_000
    } else {
        seconds = value
    }
    return Date(timeIntervalSince1970: seconds)
}
