import SwiftUI

/// Live channels and categories, side by side: swipe between them or use the switch on top.
struct BrowseView: View {
  enum Mode: String, CaseIterable, Hashable { case live = "Live", categories = "Categories" }
  @State private var mode: Mode = .live
  @StateObject private var streams = Paginator<LiveStream> { try await TwitchAPI.shared.topStreams(after: $0) }
  @StateObject private var categories = Paginator<Category> { try await TwitchAPI.shared.topCategories(after: $0) }

  var body: some View {
    TabView(selection: $mode) {
      FeedList(refresh: { [streams] in await streams.refresh() }) {
        StreamRows(paginator: streams)
      }
      .tag(Mode.live)
      FeedList(refresh: { [categories] in await categories.refresh() }) {
        CategoryRows(paginator: categories)
      }
      .tag(Mode.categories)
    }
    .tabViewStyle(.page(indexDisplayMode: .never))
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Browse", selection: $mode.animation(.easeInOut(duration: 0.3))) {
          ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 240)
      }
    }
    .navigationTitle("Browse")
    .navigationBarTitleDisplayMode(.inline)
    .task {
      if streams.items.isEmpty { await streams.refresh() }
    }
    .onChange(of: mode) { newMode in
      if newMode == .categories, categories.items.isEmpty { Task { await categories.refresh() } }
    }
  }
}

/// Live streams inside a FeedList: rows on a phone, cards in columns on a wide screen.
struct StreamRows: View {
  @ObservedObject var paginator: Paginator<LiveStream>
  var showCategory = true

  var body: some View {
    AdaptiveFeed(items: paginator.items, reached: { paginator.loadMoreIfNeeded(current: $0) }) { stream in
      StreamTile(stream: stream, showCategory: showCategory)
    }
    if paginator.isLoading {
      ProgressView().frame(maxWidth: .infinity).padding().feedRow()
    }
    if let error = paginator.error, paginator.items.isEmpty {
      ErrorBanner(message: error) { Task { await paginator.refresh() } }.feedRow()
    }
  }
}

/// Categories as rows of box art (inside a FeedList): three to a row on a phone, more on a wide
/// screen (an even number, so iPhone Duo's fold falls between them).
struct CategoryRows: View {
  @ObservedObject var paginator: Paginator<Category>
  @EnvironmentObject private var app: AppModel
  @Environment(\.feedWidth) private var width

  private var columns: Int {
    width >= 600 ? FeedGrid.columns(width, tile: 140) : 3
  }

  var body: some View {
    let columns = self.columns
    let rows = stride(from: 0, to: paginator.items.count, by: columns).map {
      Array(paginator.items[$0..<min($0 + columns, paginator.items.count)])
    }
    ForEach(rows, id: \.first?.id) { row in
      HStack(alignment: .top, spacing: 12) {
        ForEach(row) { category in
          Button {
            app.push(.category(category))
          } label: {
            CategoryTile(category: category)
          }
          .buttonStyle(PressableStyle(scale: 0.96))
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // Keep the last row's tiles the same width as the others.
        ForEach(0..<(columns - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
      }
      .feedRow(top: 8, bottom: 8)
      .onAppear { if let last = row.last { paginator.loadMoreIfNeeded(current: last) } }
    }
    if paginator.isLoading {
      ProgressView().frame(maxWidth: .infinity).padding().feedRow()
    }
    if let error = paginator.error, paginator.items.isEmpty {
      ErrorBanner(message: error) { Task { await paginator.refresh() } }.feedRow()
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
    FeedList(refresh: { [streams] in await streams.refresh() }) {
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
      .feedRow(top: 8, bottom: 10)
      StreamRows(paginator: streams, showCategory: false)
    }
    .navigationTitle(category.name)
    .navigationBarTitleDisplayMode(.inline)
    .task { if streams.items.isEmpty { await streams.refresh() } }
  }
}

@MainActor
final class SearchModel: ObservableObject {
  @Published var text = ""
  /// Earlier searches, newest first.
  @Published private(set) var history: [String] = UserDefaults.standard.stringArray(forKey: SearchModel.historyKey) ?? []
  private static let historyKey = "searchHistory.v1"
  @Published private(set) var channels: [ChannelSearchResult] = []
  @Published private(set) var categories: [Category] = []
  @Published private(set) var isLoading = false
  @Published private(set) var error: String?
  private var task: Task<Void, Never>?
  /// When the results on screen were fetched (who's live changes: old results get refreshed).
  private var searchedAt = Date.distantPast

  /// - Parameter debounce: wait a moment first (while typing).
  func search(debounce: Bool = true) {
    task?.cancel()
    let query = text.trimmingCharacters(in: .whitespaces)
    guard query.count >= 2 else {
      channels = []
      categories = []
      error = nil
      return
    }
    task = Task {
      if debounce { try? await Task.sleep(nanoseconds: 300_000_000) }
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
        searchedAt = Date()
      } catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
      }
    }
  }

  /// Back on the search after a while: fetch the results again (live or not, viewers).
  func refreshIfStale() {
    guard text.trimmingCharacters(in: .whitespaces).count >= 2, Date().timeIntervalSince(searchedAt) > 20 else { return }
    search(debounce: false)
  }

  /// Pull to refresh.
  func refresh() async {
    search(debounce: false)
    await task?.value
  }

  /// Keeps the current search in the history (when it was submitted or a result opened).
  func remember() {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= 2 else { return }
    history.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
    history.insert(query, at: 0)
    history = Array(history.prefix(25))
    UserDefaults.standard.set(history, forKey: Self.historyKey)
  }

  func forget(_ entries: [String]) {
    history.removeAll { entries.contains($0) }
    UserDefaults.standard.set(history, forKey: Self.historyKey)
  }

  func clearHistory() {
    history = []
    UserDefaults.standard.removeObject(forKey: Self.historyKey)
  }
}

struct SearchView: View {
  @StateObject private var model = SearchModel()
  @EnvironmentObject private var app: AppModel

  var body: some View {
    List {
      if model.text.trimmingCharacters(in: .whitespaces).isEmpty, !model.history.isEmpty {
        Section {
          ForEach(model.history, id: \.self) { entry in
            Button {
              model.text = entry
              model.remember()
            } label: {
              HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath").foregroundColor(.secondary)
                Text(entry).foregroundColor(.primary)
                Spacer()
                Image(systemName: "arrow.up.left").font(.footnote).foregroundColor(.secondary)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
          .onDelete { offsets in model.forget(offsets.map { model.history[$0] }) }
        } header: {
          HStack {
            Text("Recent searches")
            Spacer()
            Button("Clear") { withAnimation { model.clearHistory() } }
              .font(.footnote.weight(.semibold))
              .textCase(nil)
          }
        }
      }
      if !model.categories.isEmpty {
        Section("Categories") {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
              ForEach(model.categories) { category in
                NavigationLink(value: Route.category(category)) { CategoryTile(category: category).frame(width: 96) }
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
              NavigationLink(value: Route.channel(result.channel)) {
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
      Section { MiniPlayerSpacer() }
    }
    .listStyle(.insetGrouped)
    .environment(\.defaultMinListRowHeight, 1)
    .refreshable { [model] in await detachedRefresh { await model.refresh() } }
    .onAppear { model.refreshIfStale() }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
      model.refreshIfStale()
    }
    .overlay { if model.isLoading && model.channels.isEmpty { ProgressView() } }
    .searchable(text: $model.text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Channels and categories")
    .autocorrectionDisabled()
    .textInputAutocapitalization(.never)
    .onChange(of: model.text) { _ in model.search() }
    .onSubmit(of: .search) {
      model.search()
      model.remember()
    }
    // Opening a result keeps the search in the history.
    .onChange(of: app.searchPath.count) { count in if count > 0 { model.remember() } }
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
  /// Something to tell the user about a follow that didn't go through.
  @Published var notice: String?
  private var lastRefresh = Date.distantPast
  /// Follows changed here recently: Twitch's list can take a moment to catch up.
  private var recentChanges: [String: (follow: Bool, at: Date)] = [:]

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

  /// Follows or unfollows on Twitch, showing the change at once. If Twitch won't take it, a follow
  /// is kept in Kestrel's own list instead.
  @MainActor
  func setFollowed(_ channel: Channel, _ follow: Bool) async {
    if follow { twitchFollowIDs.insert(channel.id) } else { twitchFollowIDs.remove(channel.id) }
    recentChanges[channel.id] = (follow, Date())
    do {
      do {
        let headers = try await TwitchIntegrity.shared.headers()
        try await TwitchAPI.shared.setFollow(follow, channelID: channel.id, headers: headers)
      } catch TwitchAPIError.gql(let message) where message.localizedCaseInsensitiveContains("integrity") {
        // The token ran out or wasn't accepted: get a fresh one and try once more.
        let headers = try await TwitchIntegrity.shared.headers(refresh: true)
        try await TwitchAPI.shared.setFollow(follow, channelID: channel.id, headers: headers)
      }
      ActivityLog.shared.add(follow ? "Followed \(channel.name) on Twitch" : "Unfollowed \(channel.name) on Twitch")
      if !follow, FavoritesStore.shared.contains(channel) { FavoritesStore.shared.toggle(channel) }
      Task {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await refresh(force: true)
      }
    } catch {
      recentChanges[channel.id] = nil
      if follow { twitchFollowIDs.remove(channel.id) } else { twitchFollowIDs.insert(channel.id) }
      ActivityLog.shared.add("Couldn't \(follow ? "follow" : "unfollow") \(channel.name) on Twitch: \(error.localizedDescription)")
      if follow {
        if !FavoritesStore.shared.contains(channel) { FavoritesStore.shared.toggle(channel) }
        notice = "Twitch didn't accept the follow (\(error.localizedDescription)), so \(channel.name) was added to Kestrel's Following list instead."
      } else {
        notice = "Twitch didn't accept the unfollow (\(error.localizedDescription))."
      }
    }
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
        var ids = Set(follows.map(\.id))
        recentChanges = recentChanges.filter { Date().timeIntervalSince($0.value.at) < 120 }
        for (id, change) in recentChanges {
          if change.follow { ids.insert(id) } else { ids.remove(id) }
        }
        twitchFollowIDs = ids
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
    LiveNotifier.shared.observe(live: live, complete: problem == nil)
  }
}

struct FollowingView: View {
  @EnvironmentObject private var favorites: FavoritesStore
  @EnvironmentObject private var app: AppModel
  @ObservedObject private var store = FollowingStore.shared
  @ObservedObject private var recordings = RecordingStore.shared
  @ObservedObject private var account = TwitchAccount.shared
  @State private var showLogin = false
  @State private var showOffline = true

  var body: some View {
    FeedList(refresh: { [store] in await store.refresh(force: true) }) {
      if account.session == nil { signInCard.feedRow(top: 8) }
      if !recordings.recordings.isEmpty { recordingsRow.feedRow(top: 8, bottom: 2) }
      if let error = store.error {
        ErrorBanner(message: error) { Task { await store.refresh() } }.feedRow()
      }
      if store.loaded, store.live.isEmpty, store.offline.isEmpty, store.error == nil {
        EmptyState(
          systemImage: "heart", title: "Nobody here yet",
          message: account.session == nil
            ? "Sign in to see who you follow on Twitch, or tap the heart under a stream."
            : "Channels you follow on Twitch show up here.")
          .padding(.top, 40)
          .feedRow()
      }
      if !store.live.isEmpty {
        header("Live", count: store.live.count).feedRow(top: 10, bottom: 4)
        AdaptiveFeed(items: store.live) { stream in StreamTile(stream: stream) }
      }
      if !store.offline.isEmpty {
        Button {
          withAnimation(.easeInOut(duration: 0.25)) { showOffline.toggle() }
        } label: {
          HStack {
            header("Offline", count: store.offline.count)
            Spacer()
            Image(systemName: "chevron.down").rotationEffect(.degrees(showOffline ? 0 : -90)).foregroundColor(.secondary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .feedRow(top: 14, bottom: 4)
        if showOffline {
          AdaptiveFeed(items: store.offline, rowPadding: 5) { entry in
            Button {
              app.push(.channel(entry.channel))
            } label: {
              ChannelRow(channel: entry.channel, subtitle: entry.lastLive.map { "Last live \(Format.relative($0))" })
                .opacity(0.85)
            }
            .buttonStyle(.plain)
          }
        }
      }
      if store.isLoading && !store.loaded {
        ProgressView().frame(maxWidth: .infinity).padding(40).feedRow()
      }
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

  /// Recordings of live streams (see Recordings.swift).
  private var recordingsRow: some View {
    Button {
      app.push(.recordings)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: recordings.active.isEmpty ? "film.stack" : "record.circle.fill")
          .font(.title3)
          .foregroundColor(recordings.active.isEmpty ? .accentTeal : .liveRed)
          .frame(width: 28)
        Text("Recordings").font(.headline)
        Text("\(recordings.recordings.count)").font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
        if !recordings.active.isEmpty {
          Text("· recording \(recordings.active.count)").font(.subheadline).foregroundColor(.liveRed)
        }
        Spacer()
        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundColor(.secondary)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func header(_ title: String, count: Int) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(title).font(.title3.weight(.bold))
      Text("\(count)").font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
    }
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
  }
}
