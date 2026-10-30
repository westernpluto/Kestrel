import SwiftUI

/// Loads pages of items on demand for infinite lists.
@MainActor
final class Paginator<Item: Identifiable & Sendable>: ObservableObject {
  @Published private(set) var items: [Item] = []
  @Published private(set) var isLoading = false
  @Published private(set) var error: String?
  private var cursor: String?
  private var hasMore = true
  private var seen: Set<AnyHashable> = []
  private let fetch: (String?) async throws -> Page<Item>

  nonisolated init(fetch: @escaping (String?) async throws -> Page<Item>) {
    self.fetch = fetch
  }

  func refresh() async {
    cursor = nil
    hasMore = true
    seen = []
    await loadMore(reset: true)
  }

  func loadMoreIfNeeded(current item: Item) {
    guard let index = items.firstIndex(where: { $0.id == item.id }), index >= items.count - 6 else { return }
    Task { await loadMore(reset: false) }
  }

  func loadMore(reset: Bool) async {
    guard !isLoading, hasMore || reset else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let page = try await fetch(reset ? nil : cursor)
      let fresh = page.items.filter { seen.insert(AnyHashable($0.id)).inserted }
      if reset { items = fresh } else { items += fresh }
      cursor = page.cursor
      hasMore = page.hasNextPage && page.cursor != nil && !page.items.isEmpty
      error = nil
    } catch where error.isCancellation {
      // A refresh that was interrupted isn't an error: keep what's on screen.
    } catch {
      self.error = error.localizedDescription
      if reset { items = [] }
    }
  }
}

extension Error {
  /// A request cancelled because the screen asking for it went away (not worth showing).
  var isCancellation: Bool {
    if self is CancellationError { return true }
    if let url = self as? URLError, url.code == .cancelled { return true }
    return (self as NSError).domain == NSURLErrorDomain && (self as NSError).code == NSURLErrorCancelled
  }
}

/// Pull to refresh that isn't cut short: SwiftUI cancels a `refreshable` task as soon as the list
/// redraws mid-refresh, which cancelled the requests and showed "cancelled". The work runs in
/// its own task and the spinner waits for it.
func detachedRefresh(_ work: @escaping @MainActor () async -> Void) async {
  let started = Date()
  await Task { @MainActor in await work() }.value
  // A quick refresh still shows the spinner for a moment (snapping straight back looks broken).
  let elapsed = Date().timeIntervalSince(started)
  if elapsed < 0.45 { try? await Task.sleep(nanoseconds: UInt64((0.45 - elapsed) * 1_000_000_000)) }
}

/// A list of rows with the system's pull to refresh (the same spinner and spring-back as other
/// apps; a SwiftUI scroll view's version stuttered and left gaps). It tells what's inside how wide
/// it is, so wide screens (iPhone Duo's inner display, iPad) get tiles in columns.
struct FeedList<Content: View>: View {
  var refresh: @MainActor () async -> Void
  @ViewBuilder var content: () -> Content
  @State private var width: CGFloat = 0

  var body: some View {
    List {
      content()
      MiniPlayerSpacer()
    }
    .listStyle(.plain)
    .environment(\.defaultMinListRowHeight, 1)
    .environment(\.feedWidth, width)
    .refreshable { await detachedRefresh(refresh) }
    .background(
      GeometryReader { proxy in
        Color.clear
          .onAppear { width = proxy.size.width }
          .onChange(of: proxy.size.width) { newWidth in width = newWidth }
      }
    )
  }
}

private struct FeedWidthKey: EnvironmentKey {
  static let defaultValue: CGFloat = 0
}

private struct FeedColumnsKey: EnvironmentKey {
  static let defaultValue = 1
}

extension EnvironmentValues {
  /// The width of the feed a view is in (0 until it's measured).
  var feedWidth: CGFloat {
    get { self[FeedWidthKey.self] }
    set { self[FeedWidthKey.self] = newValue }
  }

  /// How many columns of tiles the feed shows (1: a list of rows).
  var feedColumns: Int {
    get { self[FeedColumnsKey.self] }
    set { self[FeedColumnsKey.self] = newValue }
  }
}

enum FeedGrid {
  /// One column on a phone. On a wide screen, as many tiles of at least `tile` points as fit, in
  /// an even number of columns: iPhone Duo's fold runs down the middle of its inner display, and
  /// an even count keeps it between tiles instead of across one.
  static func columns(_ width: CGFloat, tile: CGFloat = 300) -> Int {
    guard width >= 600 else { return 1 }
    return max(2, Int(width / tile) / 2 * 2)
  }
}

/// Items in a FeedList: rows on a phone, tiles in columns on a wide screen (one list row per line
/// of tiles). Tiles can read `feedColumns` to pick their look.
struct AdaptiveFeed<Item: Identifiable, Tile: View>: View {
  let items: [Item]
  /// Narrowest a tile gets on a wide screen.
  var tileWidth: CGFloat = 300
  /// Space above and below each row on a phone.
  var rowPadding: CGFloat = 7
  /// The item came on screen (to load more).
  var reached: (Item) -> Void = { _ in }
  @ViewBuilder var tile: (Item) -> Tile
  @Environment(\.feedWidth) private var width

  var body: some View {
    let columns = FeedGrid.columns(width, tile: tileWidth)
    if columns <= 1 {
      ForEach(items) { item in
        tile(item)
          .feedRow(top: rowPadding, bottom: rowPadding)
          .onAppear { reached(item) }
      }
    } else {
      let lines = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
      ForEach(lines, id: \.first?.id) { line in
        HStack(alignment: .top, spacing: 16) {
          ForEach(line) { item in
            tile(item).frame(maxWidth: .infinity, alignment: .topLeading)
          }
          // The last line's tiles stay the same width as the others.
          ForEach(0..<(columns - line.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
        }
        .environment(\.feedColumns, columns)
        .feedRow(top: 9, bottom: 9)
        .onAppear { if let last = line.last { reached(last) } }
      }
    }
  }
}

/// A live stream in a feed: a row on a phone, a card with a big picture in columns.
struct StreamTile: View {
  let stream: LiveStream
  var showCategory = true
  @Environment(\.feedColumns) private var columns

  var body: some View {
    if columns > 1 {
      StreamCard(stream: stream, showChannel: true, showCategory: showCategory)
    } else {
      StreamRow(stream: stream, showCategory: showCategory)
    }
  }
}

extension View {
  /// A row in a FeedList: no separator or highlight, with the usual margins.
  func feedRow(top: CGFloat = 6, bottom: CGFloat = 6, horizontal: CGFloat = 16) -> some View {
    listRowInsets(EdgeInsets(top: top, leading: horizontal, bottom: bottom, trailing: horizontal))
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
  }
}

struct LiveBadge: View {
  var viewers: Int?
  var body: some View {
    HStack(spacing: 4) {
      Circle().fill(Color.liveRed).frame(width: 7, height: 7)
      Text(viewers.map(Format.viewers) ?? "LIVE").font(.caption2.weight(.bold)).monospacedDigit()
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
    .foregroundColor(.white)
  }
}

/// A live stream as a compact row, like Twitch's lists: the picture on the left, who and what on
/// the right, with the stream's tags. The whole row is one tile that opens the stream (hold it for
/// the channel or category).
struct StreamRow: View {
  let stream: LiveStream
  var showCategory = true
  @EnvironmentObject private var app: AppModel

  var body: some View {
    Button {
      app.playing = .live(stream.channel)
    } label: {
      HStack(alignment: .top, spacing: 12) {
        RemoteImage(url: TwitchAPI.image(stream.previewImageURL, width: 440, height: 248))
          .aspectRatio(16 / 9, contentMode: .fit)
          .frame(width: 156)
          .overlay(alignment: .bottomLeading) {
            HStack(spacing: 3) {
              Circle().fill(Color.liveRed).frame(width: 6, height: 6)
              Text(Format.viewers(stream.viewers)).font(.caption2.weight(.semibold)).monospacedDigit()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
            .padding(5)
          }
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Avatar(url: stream.channel.profileImageURL, size: 20)
            Text(stream.channel.name).font(.subheadline.weight(.semibold)).foregroundColor(.primary).lineLimit(1)
          }
          Text(stream.title.isEmpty ? stream.channel.name : stream.title)
            .font(.footnote).foregroundColor(.secondary).lineLimit(2)
            .multilineTextAlignment(.leading)
          if showCategory, let category = stream.category {
            Text(category.name).font(.footnote).foregroundColor(.accentTeal).lineLimit(1)
          }
          if !stream.tags.isEmpty {
            ChipRow(spacing: 4) {
              ForEach(stream.tags, id: \.self) { TagChip(text: $0) }
            }
            .padding(.top, 2)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(PressableStyle(scale: 0.98))
    .contextMenu {
      Button { app.playing = .live(stream.channel) } label: { Label("Watch", systemImage: "play.fill") }
      Button { app.push(.channel(stream.channel)) } label: { Label("Open channel", systemImage: "person.crop.circle") }
      if let category = stream.category {
        Button { app.push(.category(category)) } label: { Label(category.name, systemImage: "square.grid.2x2") }
      }
    }
  }
}

struct TagChip: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Color(white: 0.17), in: Capsule())
      .foregroundColor(Color(white: 0.82))
  }
}

/// One line of chips: as many as fit, the rest left out (never a chip cut in half).
struct ChipRow: Layout {
  var spacing: CGFloat = 4

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let natural = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1))
    return CGSize(width: min(proposal.width ?? natural, natural), height: sizes.map(\.height).max() ?? 0)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var full = false
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if !full, x + size.width <= bounds.maxX + 0.5 {
        subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(size))
        x += size.width + spacing
      } else {
        full = true
        subview.place(at: CGPoint(x: bounds.minX - 10_000, y: bounds.minY), proposal: .zero)
      }
    }
  }
}

/// One tile (picture and text) that opens the stream: the channel page's "Live now", and streams
/// in columns on a wide screen (then with the channel's name, and held for more).
struct StreamCard: View {
  let stream: LiveStream
  var showChannel = false
  var showCategory = true
  @EnvironmentObject private var app: AppModel

  var body: some View {
    Button {
      app.playing = .live(stream.channel)
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        RemoteImage(url: TwitchAPI.image(stream.previewImageURL, width: 640, height: 360))
          .aspectRatio(16 / 9, contentMode: .fit)
          .overlay(alignment: .topLeading) { LiveBadge(viewers: stream.viewers).padding(8) }
          .overlay(alignment: .bottomTrailing) {
            if let uptime = Format.uptime(since: stream.startedAt) {
              Text(uptime).font(.caption2.monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4)).foregroundColor(.white).padding(8)
            }
          }
          .overlay {
            if !showChannel {
              Image(systemName: "play.fill").font(.system(size: 30, weight: .bold)).foregroundColor(.white)
                .shadow(color: .black.opacity(0.6), radius: 6)
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: 10))
        VStack(alignment: .leading, spacing: 4) {
          if showChannel {
            HStack(spacing: 6) {
              Avatar(url: stream.channel.profileImageURL, size: 22)
              Text(stream.channel.name).font(.subheadline.weight(.bold)).foregroundColor(.primary).lineLimit(1)
            }
          }
          Text(stream.title.isEmpty ? stream.channel.name : stream.title)
            .font(showChannel ? Font.subheadline : Font.subheadline.weight(.semibold))
            .foregroundColor(showChannel ? .secondary : .primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          if showCategory, let category = stream.category {
            Text(category.name).font(.footnote).foregroundColor(.accentTeal).lineLimit(1)
          }
          if !stream.tags.isEmpty {
            ChipRow(spacing: 4) {
              ForEach(stream.tags, id: \.self) { TagChip(text: $0) }
            }
          }
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(PressableStyle(scale: 0.98))
    .contextMenu {
      if showChannel {
        Button { app.playing = .live(stream.channel) } label: { Label("Watch", systemImage: "play.fill") }
        Button { app.push(.channel(stream.channel)) } label: { Label("Open channel", systemImage: "person.crop.circle") }
        if let category = stream.category {
          Button { app.push(.category(category)) } label: { Label(category.name, systemImage: "square.grid.2x2") }
        }
      }
    }
  }
}

struct ChannelRow: View {
  let channel: Channel
  var subtitle: String?
  var liveViewers: Int?

  var body: some View {
    HStack(spacing: 12) {
      Avatar(url: channel.profileImageURL, size: 44)
        .overlay(alignment: .bottomTrailing) {
          if liveViewers != nil { Circle().fill(Color.liveRed).frame(width: 12, height: 12).overlay(Circle().stroke(.black, lineWidth: 2)) }
        }
      VStack(alignment: .leading, spacing: 2) {
        Text(channel.name).font(.body.weight(.semibold))
        if let subtitle { Text(subtitle).font(.footnote).foregroundColor(.secondary).lineLimit(1) }
      }
      Spacer()
      if let liveViewers { LiveBadge(viewers: liveViewers) }
    }
    .contentShape(Rectangle())
  }
}

struct CategoryTile: View {
  let category: Category

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      RemoteImage(url: TwitchAPI.image(category.boxArtURL, width: 285, height: 380))
        .aspectRatio(285 / 380, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
      Text(category.name).font(.caption.weight(.semibold)).lineLimit(1)
      if category.viewers > 0 {
        Text("\(Format.viewers(category.viewers)) watching").font(.caption2).foregroundColor(.secondary)
      }
    }
  }
}

struct ErrorBanner: View {
  let message: String
  var retry: (() -> Void)?

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle").font(.title2).foregroundColor(.orange)
      Text(message).font(.footnote).multilineTextAlignment(.center).foregroundColor(.secondary)
      if let retry { Button("Try again", action: retry).buttonStyle(.bordered) }
    }
    .frame(maxWidth: .infinity)
    .padding(24)
  }
}

struct EmptyState: View {
  let systemImage: String
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage).font(.system(size: 40)).foregroundColor(.secondary)
      Text(title).font(.headline)
      Text(message).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(32)
  }
}

/// Shared navigation destinations for every tab.
struct AppDestinations: ViewModifier {
  func body(content: Content) -> some View {
    content
      .navigationDestination(for: Route.self) { route in
        switch route {
        case .channel(let channel): ChannelView(channel: channel).miniPlayerRoom()
        case .category(let category): CategoryView(category: category).miniPlayerRoom()
        case .recordings: RecordingsView().miniPlayerRoom()
        }
      }
  }
}

extension View {
  func appDestinations() -> some View { modifier(AppDestinations()) }
}

/// The heart: follows on Twitch when signed in (kept in sync with the account), otherwise adds the
/// channel to Kestrel's own Following list.
struct FollowButton: View {
  let channel: Channel
  var font: Font = .title3
  var tint: Color = .white
  @EnvironmentObject private var favorites: FavoritesStore
  @ObservedObject private var following = FollowingStore.shared
  @ObservedObject private var account = TwitchAccount.shared
  @State private var confirming = false

  private var onTwitch: Bool { following.twitchFollowIDs.contains(channel.id) }
  private var hearted: Bool { onTwitch || favorites.contains(channel) }

  var body: some View {
    Button {
      if account.session == nil {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { favorites.toggle(channel) }
      } else if hearted {
        confirming = true
      } else {
        Task { await following.setFollowed(channel, true) }
      }
    } label: {
      Image(systemName: hearted ? "heart.fill" : "heart")
        .font(font)
        .foregroundColor(hearted ? .liveRed : tint)
        .scaleEffect(hearted ? 1.1 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hearted)
        .frame(minWidth: 36, minHeight: 36)
        .contentShape(Rectangle())
    }
    .buttonStyle(PressableStyle(scale: 0.8))
    .accessibilityLabel(hearted ? "Unfollow" : "Follow")
    .confirmationDialog("Unfollow \(channel.name)?", isPresented: $confirming, titleVisibility: .visible) {
      Button("Unfollow", role: .destructive) {
        if onTwitch {
          Task { await following.setFollowed(channel, false) }
        } else if favorites.contains(channel) {
          favorites.toggle(channel)
        }
      }
    }
  }
}
