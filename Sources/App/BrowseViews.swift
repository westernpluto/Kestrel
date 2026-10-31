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

/// The most watched live streams right now (a couple of hundred), kept for a couple of minutes:
/// what Search shows before anything's typed, and what it looks through for titles, tags and
/// categories (Twitch's own search only knows channel and category names).
@MainActor
final class LiveIndex {
  static let shared = LiveIndex()
  private(set) var streams: [LiveStream] = []
  private var fetchedAt = Date.distantPast
  private var loading: Task<[LiveStream], Never>?

  func load(force: Bool = false) async -> [LiveStream] {
    if !force, !streams.isEmpty, Date().timeIntervalSince(fetchedAt) < 120 { return streams }
    if let loading { return await loading.value }
    let task = Task { () -> [LiveStream] in
      // Twitch's own page size (bigger pages came back empty).
      var all: [LiveStream] = []
      var cursor: String?
      for _ in 0..<7 {
        guard let page = try? await TwitchAPI.shared.topStreams(after: cursor, first: 30), !page.items.isEmpty else { break }
        all += page.items
        cursor = page.cursor
        if !page.hasNextPage || cursor == nil || all.count >= 200 { break }
      }
      return all
    }
    loading = task
    let result = await task.value
    loading = nil
    if !result.isEmpty {
      // Each channel once (a stream can show up on two pages while viewer counts move).
      var seen = Set<String>()
      streams = result.filter { seen.insert($0.channel.id).inserted }
      fetchedAt = Date()
    }
    return streams
  }

  /// Every word of the search is somewhere in the stream's title, tags, category or name.
  static func matches(_ stream: LiveStream, words: [String]) -> Bool {
    let text = ([stream.title, stream.channel.name, stream.channel.login, stream.category?.name ?? ""] + stream.tags)
      .joined(separator: " ")
    return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
  }
}

/// Channels opened from Search, newest first (the search page shows them before anything's typed).
struct RecentChannel: Codable, Hashable, Identifiable {
  var id: String
  var login: String
  var name: String
  var image: String?

  init(_ channel: Channel) {
    id = channel.id
    login = channel.login
    name = channel.name
    image = channel.profileImageURL
  }

  var channel: Channel { Channel(id: id, login: login, displayName: name, profileImageURL: image) }
}

@MainActor
final class SearchModel: ObservableObject {
  @Published var text = ""
  /// Streamers opened from Search, newest first.
  @Published private(set) var recent: [RecentChannel] = SearchModel.loadRecent()
  private static let recentKey = "searchRecentChannels.v1"
  @Published private(set) var channels: [ChannelSearchResult] = []
  /// Live streams whose title, tags or category match.
  @Published private(set) var streams: [LiveStream] = []
  @Published private(set) var categories: [Category] = []
  /// The most watched streams right now (shown before anything's typed).
  @Published private(set) var top: [LiveStream] = []
  @Published private(set) var isLoading = false
  @Published private(set) var error: String?
  private var task: Task<Void, Never>?
  /// When the results on screen were fetched (who's live changes: old results get refreshed).
  private var searchedAt = Date.distantPast

  var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// - Parameter debounce: wait a moment first (while typing).
  func search(debounce: Bool = true) {
    task?.cancel()
    let query = self.query
    guard query.count >= 2 else {
      channels = []
      streams = []
      categories = []
      error = nil
      return
    }
    task = Task {
      if debounce { try? await Task.sleep(nanoseconds: 300_000_000) }
      guard !Task.isCancelled else { return }
      isLoading = true
      defer { isLoading = false }
      let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
      async let c = TwitchAPI.shared.searchChannels(query)
      async let g = TwitchAPI.shared.searchCategories(query, first: 10)
      // A single word may be a tag ("speedrun", "English").
      async let tagged: [LiveStream] = words.count == 1 ? ((try? await TwitchAPI.shared.tagStreams(query)) ?? []) : []
      let index = Task { await LiveIndex.shared.load() }
      do {
        let (foundChannels, foundCategories) = try await (c, g)
        let fromTags = await tagged
        let live = await index.value
        guard !Task.isCancelled else { return }
        // Live channels first, then by followers.
        channels = foundChannels.sorted { a, b in
          if (a.liveViewers != nil) != (b.liveViewers != nil) { return a.liveViewers != nil }
          return (a.followers ?? 0) > (b.followers ?? 0)
        }
        categories = foundCategories
        // Streams that match by title, tag or category, most watched first (a channel found by
        // name already has its own row).
        let named = Set(channels.map(\.channel.id))
        var seen = Set<String>()
        streams = (fromTags + live.filter { LiveIndex.matches($0, words: words) })
          .filter { !named.contains($0.channel.id) && seen.insert($0.channel.id).inserted }
          .sorted { $0.viewers > $1.viewers }
          .prefix(40)
          .map { $0 }
        error = nil
        searchedAt = Date()
      } catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
      }
    }
  }

  /// Couldn't fetch what's on (shown with a retry instead of a spinner that never ends).
  @Published private(set) var topError: String?

  /// What's on before anything's typed: the first page straight away (the index for searching
  /// titles and tags fills in behind it).
  func loadTop(force: Bool = false) async {
    do {
      let page = try await TwitchAPI.shared.topStreams(first: 30)
      top = page.items
      topError = page.items.isEmpty ? "Nothing live came back from Twitch." : nil
    } catch {
      if top.isEmpty { topError = error.localizedDescription }
    }
    Task { _ = await LiveIndex.shared.load(force: force) }
  }

  /// Back on the search after a while: fetch the results again (live or not, viewers).
  func refreshIfStale() {
    guard query.count >= 2, Date().timeIntervalSince(searchedAt) > 20 else { return }
    search(debounce: false)
  }

  /// Pull to refresh.
  func refresh() async {
    if query.count >= 2 {
      search(debounce: false)
      await task?.value
    } else {
      await loadTop(force: true)
    }
  }

  /// A streamer was opened from Search: first in the recent row.
  func remember(_ channel: Channel) {
    recent.removeAll { $0.id == channel.id }
    recent.insert(RecentChannel(channel), at: 0)
    recent = Array(recent.prefix(16))
    if let data = try? JSONEncoder().encode(recent) { UserDefaults.standard.set(data, forKey: Self.recentKey) }
  }

  func forget(_ channel: RecentChannel) {
    recent.removeAll { $0.id == channel.id }
    if let data = try? JSONEncoder().encode(recent) { UserDefaults.standard.set(data, forKey: Self.recentKey) }
  }

  func clearRecent() {
    recent = []
    UserDefaults.standard.removeObject(forKey: Self.recentKey)
  }

  private static func loadRecent() -> [RecentChannel] {
    guard let data = UserDefaults.standard.data(forKey: recentKey) else { return [] }
    return (try? JSONDecoder().decode([RecentChannel].self, from: data)) ?? []
  }
}

/// Search: streamers you've looked up before and what's most watched right now until you type;
/// then channels by name, live streams by title, tag or category, and categories.
struct SearchView: View {
  @StateObject private var model = SearchModel()
  @EnvironmentObject private var app: AppModel
  /// Removing streamers from Recent: each picture shows a ✕, and a tap takes it off.
  @State private var editingRecent = false

  var body: some View {
    List {
      if model.query.isEmpty {
        if !model.recent.isEmpty { recentRow }
        if !model.top.isEmpty {
          Section {
            ForEach(model.top) { stream in liveRow(stream) }
          } header: {
            Text("Live now")
          }
        } else if let error = model.topError {
          ErrorBanner(message: error) { Task { await model.loadTop(force: true) } }
        } else {
          ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30).listRowBackground(Color.clear)
        }
      } else {
        results
      }
      Section { MiniPlayerSpacer() }
    }
    .listStyle(.insetGrouped)
    .environment(\.defaultMinListRowHeight, 1)
    // Scrolling puts the search keyboard away (a tap on a result opens it straight away).
    .scrollDismissesKeyboard(.immediately)
    .refreshable { [model] in await detachedRefresh { await model.refresh() } }
    .task { await model.loadTop() }
    .onAppear { model.refreshIfStale() }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
      model.refreshIfStale()
    }
    .searchable(text: $model.text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Streamers, titles, tags, categories")
    .autocorrectionDisabled()
    .textInputAutocapitalization(.never)
    .onChange(of: model.text) { _ in model.search() }
    .onSubmit(of: .search) { model.search(debounce: false) }
    .navigationTitle("Search")
  }

  // MARK: Before typing

  /// Streamers looked up before, as a row of pictures. Edit (or holding one) puts a ✕ on each, and
  /// a tap then takes just that one off.
  private var recentRow: some View {
    Section {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: 14) {
          ForEach(model.recent) { recent in
            recentAvatar(recent)
          }
        }
        .padding(.vertical, 6)
        .padding(.top, editingRecent ? 4 : 0)
      }
      .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
    } header: {
      HStack(spacing: 16) {
        Text("Recent")
        Spacer()
        if editingRecent {
          Button("Clear all", role: .destructive) {
            withAnimation(.easeOut(duration: 0.2)) {
              model.clearRecent()
              editingRecent = false
            }
          }
          .foregroundColor(.red)
        }
        Button(editingRecent ? "Done" : "Edit") {
          withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { editingRecent.toggle() }
        }
      }
      .font(.footnote.weight(.semibold))
      .textCase(nil)
    }
  }

  private func recentAvatar(_ recent: RecentChannel) -> some View {
    VStack(spacing: 5) {
      Avatar(url: recent.image, size: 52)
        .overlay(alignment: .topTrailing) {
          if editingRecent {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 20, weight: .semibold))
              .symbolRenderingMode(.palette)
              .foregroundStyle(.white, Color(white: 0.35))
              .background(Circle().fill(Color.black).padding(2))
              .offset(x: 6, y: -6)
              .transition(.scale.combined(with: .opacity))
          }
        }
        .scaleEffect(editingRecent ? 0.92 : 1)
      Text(recent.name).font(.caption2.weight(.medium)).foregroundColor(.primary).lineLimit(1)
        .frame(width: 64)
    }
    .contentShape(Rectangle())
    // Just this picture reacts (a link here lit up the whole row).
    .onTapGesture {
      if editingRecent {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
          model.forget(recent)
          if model.recent.isEmpty { editingRecent = false }
        }
      } else {
        model.remember(recent.channel)
        app.push(.channel(recent.channel))
      }
    }
    .onLongPressGesture(minimumDuration: 0.4) {
      guard !editingRecent else { return }
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { editingRecent = true }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(recent.name)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint(editingRecent ? "Removes it from Recent" : "Opens the channel")
    .accessibilityAction(named: "Remove from Recent") { withAnimation { model.forget(recent) } }
  }

  // MARK: Results

  @ViewBuilder
  private var results: some View {
    if !model.channels.isEmpty {
      Section("Channels") {
        ForEach(model.channels.prefix(8)) { result in
          // A plain button, not a link with a tap watcher added: that pair often swallowed the
          // tap in a list.
          Button {
            model.remember(result.channel)
            Keyboard.dismiss()
            app.push(.channel(result.channel))
          } label: {
            HStack(spacing: 8) {
              ChannelRow(
                channel: result.channel,
                subtitle: result.followers.map { "\(Format.viewers($0)) followers" },
                liveViewers: result.liveViewers)
              Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundColor(Color(white: 0.4))
            }
            .foregroundColor(.primary)
            .contentShape(Rectangle())
          }
          .buttonStyle(PressableStyle(scale: 0.98))
          .swipeActions {
            if result.liveViewers != nil {
              Button("Watch") {
                model.remember(result.channel)
                app.playing = .live(result.channel)
              }
              .tint(.accentTeal)
            }
          }
        }
      }
    }
    if !model.streams.isEmpty {
      Section("Live streams") {
        ForEach(model.streams) { stream in liveRow(stream) }
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
    if let error = model.error { ErrorBanner(message: error) { model.search() } }
    if model.query.count >= 2, !model.isLoading, model.channels.isEmpty, model.streams.isEmpty, model.categories.isEmpty,
      model.error == nil
    {
      EmptyState(systemImage: "magnifyingglass", title: "No results", message: "Try a streamer's name, a word from a title, or a tag.")
    }
    if model.isLoading, model.channels.isEmpty, model.streams.isEmpty {
      ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20).listRowBackground(Color.clear)
    }
  }

  /// A live stream, compactly: who, what, and how many are watching. Tap to watch; hold for more.
  private func liveRow(_ stream: LiveStream) -> some View {
    Button {
      model.remember(stream.channel)
      Keyboard.dismiss()
      app.playing = .live(stream.channel)
    } label: {
      HStack(spacing: 12) {
        Avatar(url: stream.channel.profileImageURL, size: 40)
          .overlay(alignment: .bottomTrailing) {
            Circle().fill(Color.liveRed).frame(width: 11, height: 11).overlay(Circle().stroke(.black, lineWidth: 2))
          }
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(stream.channel.name).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
            Spacer(minLength: 4)
            Text(Format.viewers(stream.viewers)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
          }
          .lineLimit(1)
          if !stream.title.isEmpty {
            Text(stream.title).font(.caption).foregroundColor(.secondary).lineLimit(1)
          }
          if let category = stream.category {
            Text(category.name).font(.caption2).foregroundColor(.accentTeal).lineLimit(1)
          }
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(PressableStyle(scale: 0.98))
    .contextMenu {
      Button {
        model.remember(stream.channel)
        app.playing = .live(stream.channel)
      } label: { Label("Watch", systemImage: "play.fill") }
      MultiviewMenuButton(channel: stream.channel)
      Button {
        model.remember(stream.channel)
        app.push(.channel(stream.channel))
      } label: { Label("Open channel", systemImage: "person.crop.circle") }
      if let category = stream.category {
        Button { app.push(.category(category)) } label: { Label(category.name, systemImage: "square.grid.2x2") }
      }
    }
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
    // The instant-alerts relay watches the same channels (only a complete list replaces its own).
    if problem == nil {
      let logins = (live.map(\.channel.login) + offline.map(\.channel.login)).map { $0.lowercased() }
      await InstantAlerts.shared.followsChanged(logins)
    }
  }
}

struct FollowingView: View {
  @EnvironmentObject private var favorites: FavoritesStore
  @EnvironmentObject private var app: AppModel
  @ObservedObject private var store = FollowingStore.shared
  @ObservedObject private var recordings = RecordingStore.shared
  @ObservedObject private var auto = AutoRecorder.shared
  @ObservedObject private var account = TwitchAccount.shared
  @State private var showLogin = false
  @State private var showOffline = true

  var body: some View {
    FeedList(refresh: { [store] in await store.refresh(force: true) }) {
      if account.session == nil { signInCard.feedRow(top: 8) }
      if !recordings.recordings.isEmpty || !auto.rules.isEmpty { recordingsRow.feedRow(top: 8, bottom: 2) }
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
        HStack {
          header("Live", count: store.live.count)
          Spacer()
          if store.live.count > 1 {
            // Several at once (see Multiview).
            Button {
              app.openMultiview([])
            } label: {
              Label("Multi-view", systemImage: "rectangle.split.2x2")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(PressableStyle())
          }
        }
        .feedRow(top: 10, bottom: 4)
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
