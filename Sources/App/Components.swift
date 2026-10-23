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
    } catch {
      self.error = error.localizedDescription
      if reset { items = [] }
    }
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

struct StreamCard: View {
  let stream: LiveStream
  var showCategory = true
  @EnvironmentObject private var app: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        app.playing = .live(stream.channel)
      } label: {
        RemoteImage(url: TwitchAPI.image(stream.previewImageURL, width: 640, height: 360))
          .aspectRatio(16 / 9, contentMode: .fit)
          .overlay(alignment: .topLeading) { LiveBadge(viewers: stream.viewers).padding(8) }
          .overlay(alignment: .bottomTrailing) {
            if let uptime = Format.uptime(since: stream.startedAt) {
              Text(uptime).font(.caption2.monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4)).foregroundColor(.white).padding(8)
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: 10))
      }
      .buttonStyle(.plain)

      HStack(alignment: .top, spacing: 10) {
        NavigationLink(value: stream.channel) {
          Avatar(url: stream.channel.profileImageURL, size: 36)
        }
        .buttonStyle(.plain)
        VStack(alignment: .leading, spacing: 2) {
          Text(stream.title.isEmpty ? stream.channel.name : stream.title)
            .font(.subheadline.weight(.semibold)).lineLimit(2)
          NavigationLink(value: stream.channel) {
            Text(stream.channel.name).font(.footnote).foregroundColor(.secondary)
          }
          .buttonStyle(.plain)
          if showCategory, let category = stream.category {
            NavigationLink(value: category) {
              Text(category.name).font(.footnote).foregroundColor(.accentTeal)
            }
            .buttonStyle(.plain)
          }
        }
        Spacer(minLength: 0)
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
      .navigationDestination(for: Channel.self) { ChannelView(channel: $0) }
      .navigationDestination(for: Category.self) { CategoryView(category: $0) }
  }
}

extension View {
  func appDestinations() -> some View { modifier(AppDestinations()) }
}
