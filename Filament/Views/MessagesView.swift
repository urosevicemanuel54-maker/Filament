//
//  MessagesView.swift
//  Filament
//
//  Native direct messages: the inbox from Instagram's direct_v2 API, and a
//  thread view with bubbles and a composer. Instagram's own web DM UI is kept
//  only as a fallback for when the private API refuses.
//

import Combine
import SwiftUI

struct MessagesView: View {
    @ObservedObject private var governor = RequestGovernor.shared
    @ObservedObject private var session = SessionManager.shared

    @State private var threads: [DirectThread] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showWebFallback = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if governor.isCoolingDown {
                    SlowedDownBanner { Task { await load() } }
                    Divider()
                } else if let errorMessage, !threads.isEmpty {
                    // A failed refresh keeps the list and says so, instead of
                    // replacing everything with an error screen.
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                    Divider()
                }
                content
            }
            .navigationTitle("Messages")
            .task {
                if threads.isEmpty { await load() }
            }
            .refreshable { await load() }
            .onReceive(governor.cooldownEnded) { _ in
                // The block lifted on its own: reload rather than leave the user
                // staring at Retry.
                guard threads.isEmpty else { return }
                Task { await load() }
            }
            .sheet(isPresented: $showWebFallback) {
                webFallback
            }
            .onReceive(session.$isAuthenticated) { authenticated in
                // Instagram disowned the session: drop the error and let the
                // login screen take over, rather than leave a dead screen.
                guard !authenticated else { return }
                errorMessage = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !threads.isEmpty {
            List(threads) { thread in
                NavigationLink {
                    DirectThreadView(thread: thread)
                } label: {
                    ThreadRow(thread: thread)
                }
            }
            .listStyle(.plain)
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't load messages", systemImage: "exclamationmark.bubble")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") { Task { await load() } }
                    .disabled(governor.isCoolingDown)
                Button("Use Instagram's web interface") { showWebFallback = true }
            }
        } else {
            ContentUnavailableView("No messages", systemImage: "bubble.left",
                                   description: Text("Conversations you start on Instagram show up here."))
        }
    }

    private var webFallback: some View {
        NavigationStack {
            ConstrainedInstagramWebView(
                initialURL: URL(string: "https://www.instagram.com/direct/inbox/")!,
                allowedPaths: ["/direct/", "/reel/", "/reels/"],
                lockScrollExceptPaths: ["/direct/"],
                lockScrollOnFullscreenVideo: true
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showWebFallback = false }
                }
            }
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            threads = try await InstagramAPIBridge.shared.inbox()
        } catch {
            // Keep whatever we already have on screen.
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Inbox row

private struct ThreadRow: View {
    let thread: DirectThread

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: thread.avatarURL) { $0.resizable().scaledToFill() }
                placeholder: { Color(.tertiarySystemFill) }
                .frame(width: 46, height: 46)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(thread.preview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 6) {
                Text(thread.lastActivity, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if thread.isUnseen {
                    Circle().fill(.blue).frame(width: 8, height: 8)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Thread

struct DirectThreadView: View {
    let thread: DirectThread

    @ObservedObject private var governor = RequestGovernor.shared

    @State private var messages: [DirectMessage] = []
    @State private var draft = ""
    @State private var meID = ""
    @State private var isLoading = true
    @State private var isSending = false
    @State private var errorMessage: String?

    // 20s, not 6: a thread open for five minutes was 50 requests, which on its
    // own is enough to get an account told to slow down.
    private let poll = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if governor.isCoolingDown {
                SlowedDownBanner { Task { await load() } }
                Divider()
            }
            conversation
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }
            composer
        }
        .navigationTitle(thread.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onReceive(poll) { _ in
            // Never poll through a cooldown or past a failure: that is exactly
            // the loop that keeps Instagram's block alive.
            guard !isSending, !governor.isCoolingDown, errorMessage == nil else { return }
            Task { await refresh() }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: Capsule())

            if isSending {
                ProgressView()
            } else {
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let me = try await InstagramAPIBridge.shared.currentUser()
            meID = me.id
            let content = try await InstagramAPIBridge.shared.thread(id: thread.id, meID: me.id)
            messages = content.messages
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func refresh() async {
        guard !isLoading, !meID.isEmpty else { return }
        do {
            let content = try await InstagramAPIBridge.shared.thread(id: thread.id, meID: meID)
            if content.messages != messages {
                messages = content.messages
            }
        } catch {
            // Polling is best effort; a real outage already surfaces on load/send.
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        errorMessage = nil
        draft = ""
        do {
            try await InstagramAPIBridge.shared.sendMessage(threadID: thread.id, text: text)
            let content = try await InstagramAPIBridge.shared.thread(id: thread.id, meID: meID)
            messages = content.messages
        } catch {
            errorMessage = error.localizedDescription
            draft = text
        }
        isSending = false
    }
}

// MARK: - Bubble

private struct MessageBubble: View {
    let message: DirectMessage

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 48) }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isFromMe ? Color.accentColor
                                                 : Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(message.isFromMe ? .white : .primary)

                Text(message.sentAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !message.isFromMe { Spacer(minLength: 48) }
        }
    }
}
