// Kestrel for Apple TV: the screens you browse with the Siri Remote.

import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// MARK: - Cards

/// A live stream: its picture, who and what. Focus lifts it (the card button style).
struct TVStreamCard: View {
  let stream: LiveStream
  @EnvironmentObject private var store: TVStore

  var body: some View {
    Button {
      store.watch(stream.channel)
    } label: {
      VStack(alignment: .leading, spacing: 0) {
        ZStack(alignment: .topLeading) {
          AsyncImage(url: TwitchAPI.image(stream.previewImageURL, width: 640, height: 360)) { image in
            image.resizable().aspectRatio(16 / 9, contentMode: .fill)
          } placeholder: {
            Color.white.opacity(0.08)
          }
          .aspectRatio(16 / 9, contentMode: .fit)
          .clipped()
          HStack(spacing: 6) {
            Circle().fill(Color.red).frame(width: 10, height: 10)
            Text(TVFormat.viewers(stream.viewers)).font(.caption.weight(.semibold))
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .background(.black.opacity(0.65), in: Capsule())
          .padding(12)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(stream.channel.name).font(.headline).lineLimit(1)
          Text(stream.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          if let category = stream.category?.name {
            Text(category).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .buttonStyle(.card)
  }
}

/// Streams in a grid of cards: loads more as the end comes into view.
struct TVStreamGrid: View {
  let streams: [LiveStream]
  var reachedEnd: () -> Void = {}

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 48), count: 4)

  var body: some View {
    LazyVGrid(columns: columns, spacing: 56) {
      ForEach(streams) { stream in
        TVStreamCard(stream: stream)
          .onAppear { if stream.id == streams.last?.id { reachedEnd() } }
      }
    }
    .padding(.horizontal, 60)
    .padding(.vertical, 30)
  }
}

enum TVFormat {
  static func viewers(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 10_000 { return "\(n / 1000)K" }
    if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000) }
    return "\(n)"
  }
}

/// A loading, empty or failed list, with a way to try again.
struct TVStatus: View {
  var loading: Bool
  var error: String?
  var empty: String
  var retry: () -> Void

  var body: some View {
    VStack(spacing: 24) {
      if loading {
        ProgressView()
      } else if let error {
        Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
        Button("Try again", action: retry)
      } else {
        Text(empty).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 400)
  }
}

// MARK: - Live (the most watched streams)

@MainActor
final class TVStreamFeed: ObservableObject {
  @Published private(set) var streams: [LiveStream] = []
  @Published private(set) var loading = false
  @Published private(set) var error: String?
  private var cursor: String?
  private var hasMore = true
  private let fetch: (String?) async throws -> Page<LiveStream>

  init(fetch: @escaping (String?) async throws -> Page<LiveStream>) {
    self.fetch = fetch
  }

  func refresh() async {
    cursor = nil
    hasMore = true
    streams = []
    await more()
  }

  func more() async {
    guard !loading, hasMore else { return }
    loading = true
    defer { loading = false }
    do {
      let page = try await fetch(cursor)
      let known = Set(streams.map(\.id))
      streams += page.items.filter { !known.contains($0.id) }
      cursor = page.cursor
      hasMore = page.cursor != nil && !page.items.isEmpty
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct TVBrowseView: View {
  @StateObject private var feed = TVStreamFeed { try await TwitchAPI.shared.topStreams(after: $0) }

  var body: some View {
    NavigationStack {
      ScrollView {
        if feed.streams.isEmpty {
          TVStatus(loading: feed.loading, error: feed.error, empty: "No live streams") { Task { await feed.refresh() } }
        } else {
          TVStreamGrid(streams: feed.streams) { Task { await feed.more() } }
        }
      }
      .navigationTitle("Live")
    }
    .task { if feed.streams.isEmpty { await feed.refresh() } }
  }
}

// MARK: - Following

@MainActor
final class TVFollowing: ObservableObject {
  @Published private(set) var live: [LiveStream] = []
  @Published private(set) var loading = false
  @Published private(set) var error: String?
  private var loadedAt = Date.distantPast

  func refresh(force: Bool = false) async {
    guard TwitchAuth.shared.session != nil, !loading else { return }
    guard force || Date().timeIntervalSince(loadedAt) > 60 else { return }
    loading = true
    defer { loading = false }
    do {
      let followed = try await TwitchAPI.shared.followedChannels()
      live = followed.compactMap(\.stream).sorted { $0.viewers > $1.viewers }
      loadedAt = Date()
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct TVFollowingView: View {
  @EnvironmentObject private var store: TVStore
  @StateObject private var following = TVFollowing()

  var body: some View {
    NavigationStack {
      ScrollView {
        if store.session == nil {
          VStack(spacing: 30) {
            Text("Sign in to see the channels you follow.").font(.title3).foregroundStyle(.secondary)
            Button("Sign in with Twitch") { store.tab = .settings }
          }
          .frame(maxWidth: .infinity, minHeight: 500)
        } else if following.live.isEmpty {
          TVStatus(loading: following.loading, error: following.error, empty: "None of the channels you follow are live") {
            Task { await following.refresh(force: true) }
          }
        } else {
          TVStreamGrid(streams: following.live)
        }
      }
      .navigationTitle("Following")
    }
    .task(id: store.session?.userID) { await following.refresh(force: true) }
    .onAppear { Task { await following.refresh() } }
  }
}

// MARK: - Categories

struct TVCategoriesView: View {
  @State private var categories: [Category] = []
  @State private var loading = false
  @State private var error: String?
  private let columns = Array(repeating: GridItem(.flexible(), spacing: 40), count: 6)

  var body: some View {
    NavigationStack {
      ScrollView {
        if categories.isEmpty {
          TVStatus(loading: loading, error: error, empty: "No categories") { Task { await load() } }
        } else {
          LazyVGrid(columns: columns, spacing: 50) {
            ForEach(categories) { category in
              NavigationLink(value: category) {
                VStack(spacing: 10) {
                  AsyncImage(url: TwitchAPI.image(category.boxArtURL, width: 285, height: 380)) { image in
                    image.resizable().aspectRatio(3 / 4, contentMode: .fill)
                  } placeholder: {
                    Color.white.opacity(0.08)
                  }
                  .aspectRatio(3 / 4, contentMode: .fit)
                  .clipped()
                  Text(category.name).font(.caption).lineLimit(1).padding(.horizontal, 8).padding(.bottom, 10)
                }
              }
              .buttonStyle(.card)
            }
          }
          .padding(.horizontal, 60)
          .padding(.vertical, 30)
        }
      }
      .navigationTitle("Categories")
      .navigationDestination(for: Category.self) { TVCategoryStreamsView(category: $0) }
    }
    .task { if categories.isEmpty { await load() } }
  }

  private func load() async {
    loading = true
    defer { loading = false }
    do {
      categories = try await TwitchAPI.shared.topCategories(first: 60).items
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct TVCategoryStreamsView: View {
  let category: Category
  @StateObject private var feed: TVStreamFeed

  init(category: Category) {
    self.category = category
    let id = category.id
    _feed = StateObject(wrappedValue: TVStreamFeed { try await TwitchAPI.shared.categoryStreams(id: id, after: $0) })
  }

  var body: some View {
    ScrollView {
      if feed.streams.isEmpty {
        TVStatus(loading: feed.loading, error: feed.error, empty: "No one is live in \(category.name)") {
          Task { await feed.refresh() }
        }
      } else {
        TVStreamGrid(streams: feed.streams) { Task { await feed.more() } }
      }
    }
    .navigationTitle(category.name)
    .task { if feed.streams.isEmpty { await feed.refresh() } }
  }
}

// MARK: - Search

struct TVSearchView: View {
  @EnvironmentObject private var store: TVStore
  @State private var text = ""
  @State private var channels: [ChannelSearchResult] = []
  @State private var searching = false

  var body: some View {
    NavigationStack {
      ScrollView {
        if channels.isEmpty {
          Text(text.isEmpty ? "Search for a channel" : searching ? "Searching…" : "No channels found")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 400)
        } else {
          LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(channels) { result in
              Button {
                store.watch(result.channel)
              } label: {
                HStack(spacing: 24) {
                  AsyncImage(url: result.channel.profileImageURL.flatMap(URL.init(string:))) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                  } placeholder: {
                    Color.white.opacity(0.1)
                  }
                  .frame(width: 80, height: 80)
                  .clipShape(Circle())
                  VStack(alignment: .leading, spacing: 4) {
                    Text(result.channel.name).font(.headline)
                    if let viewers = result.liveViewers {
                      Text("Live · \(TVFormat.viewers(viewers)) watching").font(.caption).foregroundStyle(.red)
                    } else {
                      Text("Offline").font(.caption).foregroundStyle(.secondary)
                    }
                  }
                  Spacer()
                }
                .padding(20)
              }
              .buttonStyle(.card)
              .disabled(result.liveViewers == nil)
            }
          }
          .padding(.horizontal, 60)
          .padding(.vertical, 30)
        }
      }
      .navigationTitle("Search")
      .searchable(text: $text, prompt: "Channels")
    }
    .task(id: text) {
      let query = text.trimmingCharacters(in: .whitespaces)
      guard !query.isEmpty else {
        channels = []
        return
      }
      searching = true
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled else { return }
      let found = (try? await TwitchAPI.shared.searchChannels(query)) ?? []
      guard !Task.isCancelled else { return }
      // Live channels first.
      channels = found.sorted { ($0.liveViewers ?? -1) > ($1.liveViewers ?? -1) }
      searching = false
    }
  }
}

// MARK: - Settings

struct TVSettingsView: View {
  @EnvironmentObject private var store: TVStore
  @State private var signingIn = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Twitch account") {
          if let session = store.session {
            LabeledContent("Signed in as", value: session.login)
            Button("Sign out", role: .destructive) { store.signOut() }
          } else {
            Button("Sign in with Twitch") { signingIn = true }
          }
        }
        Section {
          Toggle("Ad blocking", isOn: $store.adBlocking)
        } footer: {
          Text("Plays streams through ad-free servers (the iPhone app's Automatic ad blocking). Off, streams come straight from Twitch, ads included unless you're subscribed or have Turbo.")
        }
        Section {
          Toggle("Chat beside the video", isOn: $store.chatShown)
        } footer: {
          Text("In the player, press left or right on the remote to show or hide chat.")
        }
        Section {
          LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        }
      }
      .navigationTitle("Settings")
    }
    .fullScreenCover(isPresented: $signingIn) { TVSignInView().environmentObject(store) }
  }
}

/// Signing in with a code: shown big, with a QR code that opens Twitch's activation page with the
/// code filled in. Kestrel checks every few seconds until it's approved.
struct TVSignInView: View {
  @EnvironmentObject private var store: TVStore
  @Environment(\.dismiss) private var dismiss
  @State private var code: TwitchDeviceLogin.Code?
  @State private var message: String?

  var body: some View {
    VStack(spacing: 40) {
      Text("Sign in with Twitch").font(.largeTitle.weight(.bold))
      if let code {
        HStack(spacing: 80) {
          if let qr = Self.qrCode(code.verificationURI) {
            Image(uiImage: qr).interpolation(.none).resizable().frame(width: 320, height: 320)
              .padding(20).background(.white, in: RoundedRectangle(cornerRadius: 16))
          }
          VStack(alignment: .leading, spacing: 24) {
            Text("On your phone or computer, go to").foregroundStyle(.secondary)
            Text("twitch.tv/activate").font(.title2.weight(.semibold))
            Text("and enter").foregroundStyle(.secondary)
            Text(code.userCode).font(.system(size: 72, weight: .bold, design: .monospaced)).tracking(6)
            Text("Or scan the code with your phone's camera.").font(.caption).foregroundStyle(.secondary)
          }
        }
      } else if message == nil {
        ProgressView()
      }
      if let message { Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center) }
      Button("Cancel") { dismiss() }
    }
    .padding(80)
    .task { await run() }
  }

  private func run() async {
    let http = URLSessionHTTPClient(timeout: 15)
    while !Task.isCancelled {
      do {
        let fresh = try await TwitchDeviceLogin.start(http: http)
        code = fresh
        message = nil
        var interval = fresh.interval
        polling: while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
          switch await TwitchDeviceLogin.poll(fresh, http: http) {
          case .pending:
            if Date() > fresh.expiresAt { break polling }
          case .slowDown:
            interval += 5
          case .expired:
            break polling  // a new code
          case .refused(let reason):
            message = "Twitch said: \(reason)"
            return
          case .done(let grant):
            await finish(grant, http: http)
            return
          }
        }
      } catch {
        message = error.localizedDescription
        try? await Task.sleep(nanoseconds: 5_000_000_000)
      }
    }
  }

  private func finish(_ grant: TwitchDeviceLogin.Grant, http: HTTPClient) async {
    do {
      let who = try await TwitchAuth.validate(token: grant.accessToken, http: http, clientID: TwitchDeviceLogin.clientID)
      store.save(
        TwitchAuth.Session(
          token: grant.accessToken, login: who.login, userID: who.userID, deviceID: nil, clientID: TwitchDeviceLogin.clientID,
          refreshToken: grant.refreshToken))
      store.tab = .following
      dismiss()
    } catch {
      message = error.localizedDescription
    }
  }

  private static func qrCode(_ text: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage,
      let image = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return UIImage(cgImage: image)
  }
}
