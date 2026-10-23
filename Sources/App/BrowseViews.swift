import SwiftUI

struct BrowseView: View {
  enum Mode: String, CaseIterable { case live = "Live", categories = "Categories" }
  @State private var mode: Mode = .live
  @StateObject private var streams = Paginator<LiveStream> { try await TwitchAPI.shared.topStreams(after: $0) }
  @StateObject private var categories = Paginator<Category> { try await TwitchAPI.shared.topCategories(after: $0) }

  var body: some View {
    ScrollView {
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
    .refreshable {
      if mode == .live { await streams.refresh() } else { await categories.refresh() }
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
    ScrollView {
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
    .refreshable { await streams.refresh() }
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

@MainActor
final class FollowingModel: ObservableObject {
  @Published private(set) var live: [LiveStream] = []
  @Published private(set) var offline: [Channel] = []
  @Published private(set) var isLoading = false
  @Published private(set) var error: String?

  func refresh(_ channels: [Channel]) async {
    guard !channels.isEmpty else {
      live = []
      offline = []
      return
    }
    isLoading = true
    defer { isLoading = false }
    do {
      let results = try await TwitchAPI.shared.users(logins: channels.map(\.login))
      FavoritesStore.shared.refresh(results.map(\.0))
      live = results.compactMap(\.1).sorted { $0.viewers > $1.viewers }
      let liveIDs = Set(live.map(\.channel.id))
      offline = channels.filter { !liveIDs.contains($0.id) }.sorted { $0.name.lowercased() < $1.name.lowercased() }
      error = nil
    } catch {
      self.error = error.localizedDescription
      offline = channels
    }
  }
}

struct FollowingView: View {
  @EnvironmentObject private var favorites: FavoritesStore
  @StateObject private var model = FollowingModel()

  var body: some View {
    ScrollView {
      if favorites.channels.isEmpty {
        EmptyState(
          systemImage: "heart", title: "No followed channels yet",
          message: "Tap the heart on a channel to follow it. Follows are saved on this device.")
          .padding(.top, 60)
      } else {
        if let error = model.error { ErrorBanner(message: error) { Task { await model.refresh(favorites.channels) } } }
        if !model.live.isEmpty {
          LazyVStack(alignment: .leading, spacing: 22) {
            Text("Live").font(.title3.weight(.bold))
            ForEach(model.live) { StreamCard(stream: $0) }
          }
          .padding()
        }
        if !model.offline.isEmpty {
          LazyVStack(alignment: .leading, spacing: 12) {
            Text("Offline").font(.title3.weight(.bold))
            ForEach(model.offline) { channel in
              NavigationLink(value: channel) { ChannelRow(channel: channel) }.buttonStyle(.plain)
            }
          }
          .padding()
        }
        if model.isLoading && model.live.isEmpty && model.offline.isEmpty { ProgressView().padding(40) }
      }
    }
    .refreshable { await model.refresh(favorites.channels) }
    .navigationTitle("Following")
    .task(id: favorites.channels.map(\.id)) { await model.refresh(favorites.channels) }
  }
}
