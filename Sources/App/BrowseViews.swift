import SwiftUI

struct BrowseView: View {
  enum Mode: String, CaseIterable { case live = "Live", categories = "Categories" }
  @State private var mode: Mode = .live
  @StateObject private var streams = Paginator<LiveStream> { try await TwitchAPI.shared.topStreams(after: $0) }
  @StateObject private var categories = Paginator<Category> { try await TwitchAPI.shared.topCategories(after: $0) }

  var body: some View {
    RefreshableScrollView(refresh: { [mode, streams, categories] in
      if mode == .live { await streams.refresh() } else { await categories.refresh() }
    }) {
      Picker("", selection: $mode) {
        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.top, 4)

      switch mode {
      case .live:
        StreamList(paginator: streams)
      case .categories:
        CategoryGrid(paginator: categories)
      }
    }
    .navigationTitle("Browse")
    .task {
      if streams.items.isEmpty { await streams.refresh() }
    }
    .onChange(of: mode) { newMode in
      if newMode == .categories, categories.items.isEmpty { Task { await categories.refresh() } }
    }
  }
}

struct StreamList: View {
  @ObservedObject var paginator: Paginator<LiveStream>
  var showCategory = true

  var body: some View {
    LazyVStack(spacing: 22) {
      ForEach(paginator.items) { stream in
        StreamCard(stream: stream, showCategory: showCategory)
          .onAppear { paginator.loadMoreIfNeeded(current: stream) }
      }
      if paginator.isLoading { ProgressView().padding() }
      if let error = paginator.error, paginator.items.isEmpty {
        ErrorBanner(message: error) { Task { await paginator.refresh() } }
      }
    }
    .padding()
  }
}

struct CategoryGrid: View {
  @ObservedObject var paginator: Paginator<Category>
  private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

  var body: some View {
    LazyVGrid(columns: columns, spacing: 16) {
      ForEach(paginator.items) { category in
        NavigationLink(value: category) { CategoryTile(category: category) }
          .buttonStyle(.plain)
          .onAppear { paginator.loadMoreIfNeeded(current: category) }
      }
    }
    .padding()
    if paginator.isLoading { ProgressView().padding() }
    if let error = paginator.error, paginator.items.isEmpty {
      ErrorBanner(message: error) { Task { await paginator.refresh() } }
    }
  }
}

struct CategoryView: View {
  let category: Category
  @StateObject private var streams: Paginator<LiveStream>

  init(category: Category) {
    self.category = category
    let id = category.id
    _streams = StateObject(wrappedValue: Paginator { try await TwitchAPI.shared.categoryStreams(id: id, after: $0) })
  }

  var body: some View {
    RefreshableScrollView(refresh: { [streams] in await streams.refresh() }) {
      HStack(alignment: .top, spacing: 14) {
        RemoteImage(url: TwitchAPI.image(category.boxArtURL, width: 285, height: 380))
          .frame(width: 72, height: 96)
          .clipShape(RoundedRectangle(cornerRadius: 6))
        VStack(alignment: .leading, spacing: 4) {
          Text(category.name).font(.title3.weight(.bold))
          if category.viewers > 0 {
            Text("\(Format.viewers(category.viewers)) watching").font(.subheadline).foregroundColor(.secondary)
          }
        }
        Spacer()
      }
      .padding(.horizontal)
      StreamList(paginator: streams, showCategory: false)
    }
    .navigationTitle(category.name)
    .navigationBarTitleDisplayMode(.inline)
    .task { if streams.items.isEmpty { await streams.refresh() } }
  }
}

@MainActor
final class SearchModel: ObservableObject {
  @Published var text = ""
  @Published private(set) var channels: [ChannelSearchResult] = []
  @Published private(set) var categories: [Category] = []
  @Published private(set) var isLoading = false
  @Published private(set) var error: String?
  private var task: Task<Void, Never>?

  func search() {
    task?.cancel()
    let query = text.trimmingCharacters(in: .whitespaces)
    guard query.count >= 2 else {
      channels = []
      categories = []
      error = nil
      return
    }
    task = Task {
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard !Task.isCancelled else { return }
      isLoading = true
      defer { isLoading = false }
      do {
        async let c = TwitchAPI.shared.searchChannels(query)
        async let g = TwitchAPI.shared.searchCategories(query, first: 10)
        let (foundChannels, foundCategories) = try await (c, g)
        guard !Task.isCancelled else { return }
        // Live channels first, then by followers.
        channels = foundChannels.sorted { a, b in
          if (a.liveViewers != nil) != (b.liveViewers != nil) { return a.liveViewers != nil }
          return (a.followers ?? 0) > (b.followers ?? 0)
        }
        categories = foundCategories
        error = nil
      } catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
      }
    }
  }
}

struct SearchView: View {
  @StateObject private var model = SearchModel()
  @EnvironmentObject private var app: AppModel

  var body: some View {
    List {
      if !model.categories.isEmpty {
        Section("Categories") {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
              ForEach(model.categories) { category in
                NavigationLink(value: category) { CategoryTile(category: category).frame(width: 96) }
                  .buttonStyle(.plain)
              }
            }
            .padding(.vertical, 4)
          }
        }
      }
      if !model.channels.isEmpty {
        Section("Channels") {
          ForEach(model.channels) { result in
            HStack {
              NavigationLink(value: result.channel) {
                ChannelRow(
                  channel: result.channel,
                  subtitle: result.followers.map { "\(Format.viewers($0)) followers" },
                  liveViewers: result.liveViewers)
              }
            }
            .swipeActions {
              if result.liveViewers != nil {
                Button("Watch") { app.playing = .live(result.channel) }.tint(.accentTeal)
              }
            }
          }
        }
      }
      if let error = model.error { ErrorBanner(message: error) { model.search() } }
      if model.text.count >= 2, !model.isLoading, model.channels.isEmpty, model.categories.isEmpty, model.error == nil {
        EmptyState(systemImage: "magnifyingglass", title: "No results", message: "Try a different name.")
      }
    }
    .listStyle(.insetGrouped)
    .overlay { if model.isLoading && model.channels.isEmpty { ProgressView() } }
    .searchable(text: $model.text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Channels and categories")
    .autocorrectionDisabled()
    .textInputAutocapitalization(.never)
    .onChange(of: model.text) { _ in model.search() }
    .onSubmit(of: .search) { model.search() }
    .navigationTitle("Search")
  }
}

/// Who you follow: your Twitch follows when signed in, plus channels hearted in Kestrel.
@MainActor
final class FollowingStore: ObservableObject {
  static let shared = FollowingStore()

  struct OfflineChannel: Identifiable {
    var channel: Channel
    var lastLive: Date?
    var id: String { channel.id }
  }

  @Published private(set) var live: [LiveStream] = []
  @Published private(set) var offline: [OfflineChannel] = []
  /// Channels followed on Twitch (the player shows these hearts filled).
  @Published private(set) var twitchFollowIDs: Set<String> = []
  @Published private(set) var isLoading = false
  @Published private(set) var loaded = false
  @Published private(set) var error: String?
  private var lastRefresh = Date.distantPast

  private var current: Task<Void, Never>?

  func refreshIfStale() async {
    if Date().timeIntervalSince(lastRefresh) > 60 { await refresh() }
  }

  /// Runs one refresh at a time; a pull to refresh waits for the one already running.
  func refresh(force: Bool = false) async {
    if let current {
      await current.value
      if !force { return }
    }
    let task = Task { await load() }
    current = task
    await task.value
    current = nil
  }

  private func load() async {
    isLoading = true
    defer { isLoading = false }
    lastRefresh = Date()
    var liveByID: [String: LiveStream] = [:]
    var offlineByID: [String: OfflineChannel] = [:]
    var problem: String?

    if TwitchAccount.shared.session != nil {
      do {
        let follows = try await TwitchAPI.shared.followedChannels()
        twitchFollowIDs = Set(follows.map(\.id))
        for follow in follows {
          if let stream = follow.stream {
            liveByID[follow.id] = stream
          } else {
            offlineByID[follow.id] = OfflineChannel(channel: follow.channel, lastLive: follow.lastLive)
          }
        }
      } catch where error.isCancellation {
      } catch {
        problem = "Couldn't load your Twitch follows (\(error.localizedDescription))."
      }
    } else {
      twitchFollowIDs = []
    }

    let hearted = FavoritesStore.shared.channels.filter { liveByID[$0.id] == nil && offlineByID[$0.id] == nil }
    if !hearted.isEmpty {
      do {
        let results = try await TwitchAPI.shared.users(logins: hearted.map(\.login))
        FavoritesStore.shared.refresh(results.map(\.0))
        for (channel, stream) in results {
          if let stream { liveByID[channel.id] = stream } else { offlineByID[channel.id] = OfflineChannel(channel: channel) }
        }
      } catch where error.isCancellation {
      } catch {
        problem = problem ?? error.localizedDescription
      }
      for channel in hearted where liveByID[channel.id] == nil && offlineByID[channel.id] == nil {
        offlineByID[channel.id] = OfflineChannel(channel: channel)
      }
    }

    live = liveByID.values.sorted { $0.viewers > $1.viewers }
    offline = offlineByID.values.sorted { a, b in
      switch (a.lastLive, b.lastLive) {
      case let (x?, y?): return x > y
      case (.some, nil): return true
      case (nil, .some): return false
      case (nil, nil): return a.channel.name.lowercased() < b.channel.name.lowercased()
      }
    }
    error = problem
    loaded = true
  }
}

struct FollowingView: View {
  @EnvironmentObject private var favorites: FavoritesStore
  @ObservedObject private var store = FollowingStore.shared
  @ObservedObject private var account = TwitchAccount.shared
  @State private var showLogin = false
  @State private var showOffline = true

  var body: some View {
    RefreshableScrollView(refresh: { [store] in await store.refresh(force: true) }) {
      LazyVStack(alignment: .leading, spacing: 0) {
        if account.session == nil { signInCard }
        if let error = store.error {
          ErrorBanner(message: error) { Task { await store.refresh() } }
        }
        if store.loaded, store.live.isEmpty, store.offline.isEmpty, store.error == nil {
          EmptyState(
            systemImage: "heart", title: "Nobody here yet",
            message: account.session == nil
              ? "Sign in to see who you follow on Twitch, or tap the heart under a stream."
              : "Channels you follow on Twitch show up here.")
            .padding(.top, 40)
        }
        if !store.live.isEmpty {
          header("Live", count: store.live.count)
          ForEach(store.live) { stream in
            StreamCard(stream: stream).padding(.bottom, 22)
          }
        }
        if !store.offline.isEmpty {
          Button {
            withAnimation(.easeInOut(duration: 0.2)) { showOffline.toggle() }
          } label: {
            HStack {
              header("Offline", count: store.offline.count)
              Spacer()
              Image(systemName: "chevron.down").rotationEffect(.degrees(showOffline ? 0 : -90)).foregroundColor(.secondary)
            }
          }
          .buttonStyle(.plain)
          if showOffline {
            ForEach(store.offline) { entry in
              NavigationLink(value: entry.channel) {
                ChannelRow(channel: entry.channel, subtitle: entry.lastLive.map { "Last live \(Format.relative($0))" })
                  .opacity(0.85)
              }
              .buttonStyle(.plain)
              .padding(.vertical, 6)
            }
          }
        }
        if store.isLoading && !store.loaded {
          ProgressView().frame(maxWidth: .infinity).padding(40)
        }
      }
      .padding(.horizontal)
      .padding(.bottom)
    }
    .navigationTitle("Following")
    .task(id: refreshKey) { await store.refresh() }
    .onAppear { Task { await store.refreshIfStale() } }
    .sheet(isPresented: $showLogin) { TwitchLoginView() }
  }

  /// Reload when the account or the hearted channels change.
  private var refreshKey: String {
    (account.session?.login ?? "-") + "|" + favorites.channels.map(\.id).joined(separator: ",")
  }

  private func header(_ title: String, count: Int) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(title).font(.title3.weight(.bold))
      Text("\(count)").font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
    }
    .padding(.top, 14)
    .padding(.bottom, 10)
  }

  private var signInCard: some View {
    Button {
      showLogin = true
    } label: {
      HStack(spacing: 12) {
        Image(systemName: "person.crop.circle.badge.plus").font(.title2).foregroundColor(.accentTeal)
        VStack(alignment: .leading, spacing: 2) {
          Text("Sign in with Twitch").font(.subheadline.weight(.semibold)).foregroundColor(.primary)
          Text("See who you follow and chat as yourself").font(.footnote).foregroundColor(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right").foregroundColor(.secondary)
      }
      .padding(14)
      .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .padding(.top, 8)
  }
}
