//
//  FeedView.swift
//  Filament
//
//  Native, chronological, following-only feed. ScrollView + LazyVStack of
//  native PostView rows fed by InstagramAPIBridge. Explicit "Load More" cursor
//  paging (next_max_id). Stories tray pinned at the top.
//

import SwiftUI
import Combine

@MainActor
final class FeedViewModel: ObservableObject {
    @Published private(set) var posts: [Post] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    @Published var errorMessage: String?

    private var nextMaxId: String?

    func loadInitial() async {
        // A refresh that fails must not wipe the feed: hold the old state and
        // put it back if the reload came away empty.
        let previousPosts = posts
        let previousMaxId = nextMaxId
        let previousHasMore = hasMore

        nextMaxId = nil
        hasMore = true
        posts = []

        await loadMore()

        if posts.isEmpty, !previousPosts.isEmpty, errorMessage != nil {
            posts = previousPosts
            nextMaxId = previousMaxId
            hasMore = previousHasMore
        }
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        errorMessage = nil
        do {
            let page = try await InstagramAPIBridge.shared.feed(maxId: nextMaxId)
            posts.append(contentsOf: page.posts)
            nextMaxId = page.nextMaxId
            hasMore = page.moreAvailable
            // Warm the cache for the page just appended, so scrolling into it
            // finds the photos locally instead of starting downloads.
            ImagePrefetcher.shared.prefetch(page.posts.compactMap { $0.imageURLs.first })
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct FeedView: View {
    @StateObject private var model = FeedViewModel()
    @ObservedObject private var governor = RequestGovernor.shared
    @ObservedObject private var session = SessionManager.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if governor.isCoolingDown {
                    SlowedDownBanner { Task { await model.loadInitial() } }
                    Divider()
                }
                scroll
            }
            .navigationTitle("Filament")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var scroll: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                StoriesView()
                Divider()
                ForEach(model.posts) { post in
                    PostView(post: post)
                    Divider()
                }
                footer
            }
        }
        .refreshable { await model.loadInitial() }
        .task { if model.posts.isEmpty { await model.loadInitial() } }
        .onReceive(session.$isAuthenticated) { authenticated in
            // Instagram disowned the session: drop the error and let the
            // login screen take over, rather than leave a dead feed.
            guard !authenticated else { return }
            model.errorMessage = nil
        }
        .onReceive(governor.cooldownEnded) { _ in
            // The block lifted on its own: fill the empty feed back in.
            guard model.posts.isEmpty else { return }
            Task { await model.loadInitial() }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.isLoading {
            ProgressView().padding(24)
        } else if let error = model.errorMessage {
            VStack(spacing: 8) {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await model.loadMore() } }
                    .disabled(governor.isCoolingDown)
            }
            .padding(24)
        } else if model.hasMore {
            Button("Load More") { Task { await model.loadMore() } }
                .padding(24)
        }
    }
}

struct PostView: View {
    let post: Post
    @State private var liked: Bool
    @State private var likeCount: Int
    @State private var showComments = false
    @State private var likeError: String?

    init(post: Post) {
        self.post = post
        _liked = State(initialValue: post.hasLiked)
        _likeCount = State(initialValue: post.likeCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            media
            actions
            caption
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showComments) {
            CommentsSheet(post: post)
        }
        .alert("Couldn't update like", isPresented: Binding(
            get: { likeError != nil },
            set: { if !$0 { likeError = nil } }
        ), presenting: likeError) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AsyncImage(url: post.author.profilePicURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color(.tertiarySystemFill)
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())

            Text(post.author.username).font(.subheadline.bold())
            if post.author.isVerified {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.blue).font(.caption)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var media: some View {
        if post.imageURLs.count > 1 {
            TabView {
                ForEach(post.imageURLs, id: \.self) { url in
                    squareImage(url)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .aspectRatio(1, contentMode: .fit)
        } else if let url = post.imageURLs.first {
            squareImage(url)
        }
    }

    // A full-width square that fills with the image — sizes from the container,
    // so it's correct on any device/window without reaching for UIScreen.
    private func squareImage(_ url: URL) -> some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .empty: ProgressView()
                    case .failure: Image(systemName: "photo").foregroundStyle(.secondary)
                    @unknown default: EmptyView()
                    }
                }
            }
            .clipped()
    }

    private var actions: some View {
        HStack(spacing: 18) {
            Button {
                Task { await toggleLike() }
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .foregroundStyle(liked ? .red : .primary)
            }
            Button {
                showComments = true
            } label: {
                Image(systemName: "bubble.right")
            }
            .foregroundStyle(.primary)
            if let url = post.permalink {
                ShareLink(item: url) {
                    Image(systemName: "paperplane")
                }
                .foregroundStyle(.primary)
            } else {
                Image(systemName: "paperplane").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.title3)
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(likeCount) likes").font(.subheadline.bold())
            if let text = post.caption, !text.isEmpty {
                Text("**\(post.author.username)** \(text)")
                    .font(.subheadline)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 12)
    }

    private func toggleLike() async {
        let newLiked = !liked
        liked = newLiked
        likeCount += newLiked ? 1 : -1
        do {
            // Private API first; the web-UI bridge is only the fallback, so a
            // like no longer costs a whole page load.
            try await InstagramAPIBridge.shared.setLike(newLiked, on: post)
        } catch {
            // Revert optimistic update on failure — and surface why.
            liked = !newLiked
            likeCount += newLiked ? -1 : 1
            likeError = error.localizedDescription
        }
    }
}

// MARK: - Comments (native)

struct CommentsSheet: View {
    let post: Post
    @Environment(\.dismiss) private var dismiss

    @State private var comments: [Comment] = []
    @State private var me: User?
    @State private var draft = ""
    @State private var isLoading = true
    @State private var isSending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if comments.isEmpty {
                    ContentUnavailableView("No comments yet", systemImage: "bubble",
                                           description: Text("Be the first to comment."))
                } else {
                    List(comments) { CommentRow(comment: $0) }
                        .listStyle(.plain)
                }
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .task { await load() }
        }
    }

    private var composer: some View {
        VStack(spacing: 4) {
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                AsyncImage(url: me?.profilePicURL) { $0.resizable().scaledToFill() }
                    placeholder: { Color(.tertiarySystemFill) }
                    .frame(width: 30, height: 30).clipShape(Circle())
                TextField("Add a comment…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                if isSending {
                    ProgressView()
                } else {
                    Button("Post") { Task { await send() } }
                        .fontWeight(.semibold)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    private func load() async {
        isLoading = true
        async let fetchedComments = try? InstagramAPIBridge.shared.comments(for: post)
        async let fetchedMe = try? InstagramAPIBridge.shared.currentUser()
        comments = await fetchedComments ?? []
        me = await fetchedMe
        isLoading = false
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        error = nil
        // Optimistic insert.
        let optimistic = me.map { Comment(id: UUID().uuidString, user: $0, text: text, createdAt: Date()) }
        if let optimistic { comments.insert(optimistic, at: 0) }
        draft = ""
        do {
            // Private API first, web UI as the fallback.
            try await InstagramAPIBridge.shared.postComment(on: post, text: text)
        } catch {
            if let optimistic { comments.removeAll { $0.id == optimistic.id } }
            self.error = error.localizedDescription
            draft = text
        }
        isSending = false
    }
}

private struct CommentRow: View {
    let comment: Comment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: comment.user.profilePicURL) { $0.resizable().scaledToFill() }
                placeholder: { Color(.tertiarySystemFill) }
                .frame(width: 32, height: 32).clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("**\(comment.user.username)** \(comment.text)").font(.subheadline)
                if comment.createdAt.timeIntervalSince1970 > 0 {
                    Text(comment.createdAt, style: .relative)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
