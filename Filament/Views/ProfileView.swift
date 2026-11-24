//
//  ProfileView.swift
//  Filament
//
//  The logged-in user's profile, rendered natively from the private API:
//  header with counts, then the post grid.
//

import Combine
import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var session: SessionManager
    @ObservedObject private var governor = RequestGovernor.shared

    @State private var profile: UserProfile?
    @State private var posts: [Post] = []
    @State private var nextMaxId: String?
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if governor.isCoolingDown {
                    SlowedDownBanner { Task { await load() } }
                    Divider()
                } else if let errorMessage, profile != nil {
                    // A failed reload keeps the profile on screen and says so.
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                    Divider()
                }
                bodyContent(profile)
            }
            .navigationTitle(profile?.username ?? "Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Log Out", role: .destructive) {
                        Task { await session.logout() }
                    }
                }
            }
            .task {
                if profile == nil { await load() }
            }
            .onReceive(session.$isAuthenticated) { authenticated in
                guard !authenticated else { return }
                errorMessage = nil
            }
            .onReceive(governor.cooldownEnded) { _ in
                // Nothing on screen to keep: the block just lifted, so fetch.
                guard profile == nil else { return }
                Task { await load() }
            }
        }
    }

    @ViewBuilder
    private func bodyContent(_ profile: UserProfile?) -> some View {
        if let profile {
            content(profile)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't load profile", systemImage: "person.slash")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") { Task { await load() } }
                    .disabled(governor.isCoolingDown)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Content

    private func content(_ profile: UserProfile) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header(profile)
                grid
                footer
            }
            .padding(.top, 8)
        }
        .refreshable { await load() }
    }

    private func header(_ profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                AsyncImage(url: profile.profilePicURL) { $0.resizable().scaledToFill() }
                    placeholder: { Color(.tertiarySystemFill) }
                    .frame(width: 86, height: 86)
                    .clipShape(Circle())

                HStack(spacing: 22) {
                    stat(profile.postCount, label: "posts")
                    stat(profile.followerCount, label: "followers")
                    stat(profile.followingCount, label: "following")
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(profile.fullName.isEmpty ? profile.username : profile.fullName)
                        .font(.subheadline.bold())
                    if profile.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
                if !profile.biography.isEmpty {
                    Text(profile.biography).font(.footnote)
                }
                if profile.isPrivate {
                    Label("Private account", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func stat(_ value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value, format: .number.notation(.compactName))
                .font(.headline)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(posts) { post in
                square(post)
            }
        }
    }

    private func square(_ post: Post) -> some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let url = post.imageURLs.first {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        case .empty: ProgressView()
                        default: Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .clipped()
    }

    @ViewBuilder
    private var footer: some View {
        if isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        } else if hasMore {
            Button("Load more") {
                Task { await loadMore() }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Loading

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let me = try await InstagramAPIBridge.shared.currentUser()
            // One request for the header and the first grid page, on the
            // endpoint the web client uses; the bridge falls back to the older
            // pair if that one is refused.
            let snapshot = try await InstagramAPIBridge.shared.profileSnapshot(username: me.username)
            profile = snapshot.profile
            posts = snapshot.page.posts
            nextMaxId = snapshot.page.nextMaxId
            hasMore = snapshot.page.moreAvailable
            ImagePrefetcher.shared.prefetch(posts.prefix(6).compactMap { $0.imageURLs.first })
        } catch {
            // Whatever loaded stays on screen; the header only shows the error
            // when there is nothing else to show.
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard hasMore, !isLoadingMore, let profile else { return }
        isLoadingMore = true
        do {
            let page = try await InstagramAPIBridge.shared.userPosts(userID: profile.id,
                                                                    maxId: nextMaxId)
            posts += page.posts
            nextMaxId = page.nextMaxId
            hasMore = page.moreAvailable
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingMore = false
    }
}
