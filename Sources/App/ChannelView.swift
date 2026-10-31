import SwiftUI
import UIKit

@MainActor
final class ChannelModel: ObservableObject {
  @Published var page: ChannelPage?
  @Published var error: String?
  @Published var isLoading = false
  private(set) var loadedAt = Date.distantPast
  let videos: Paginator<Video>
  let login: String

  nonisolated init(login: String) {
    self.login = login
    videos = Paginator { try await TwitchAPI.shared.videos(login: login, after: $0) }
  }

  func load() async {
    isLoading = true
    defer { isLoading = false }
    loadedAt = Date()
    do {
      page = try await TwitchAPI.shared.channelPage(login: login)
      error = page == nil ? "Channel not found." : nil
    } catch where error.isCancellation {
    } catch {
      self.error = error.localizedDescription
    }
    await videos.refresh()
  }
}

struct ChannelView: View {
  let channel: Channel
  @StateObject private var model: ChannelModel
  @EnvironmentObject private var favorites: FavoritesStore
  @EnvironmentObject private var app: AppModel

  init(channel: Channel) {
    self.channel = channel
    _model = StateObject(wrappedValue: ChannelModel(login: channel.login))
  }

  private var current: Channel { model.page?.channel ?? channel }

  var body: some View {
    FeedList(refresh: { [model] in await model.load() }) {
      header.feedRow(top: 12, bottom: 8)
      if let stream = model.page?.stream {
        VStack(alignment: .leading, spacing: 6) {
          Text("Live now").font(.headline)
          StreamCard(stream: stream)
        }
        .feedRow(top: 6, bottom: 10)
      } else if model.page != nil {
        HStack(spacing: 8) {
          Image(systemName: "moon.zzz").foregroundColor(.secondary)
          Text(model.page?.lastBroadcast.map { "Offline · last live \(Format.relative($0))" } ?? "Offline")
            .foregroundColor(.secondary)
            .lineLimit(1)
          Spacer(minLength: 8)
          // Their chat while they're offline; the stream's offered once they go live.
          Button {
            app.openChat(current)
          } label: {
            Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
              .font(.subheadline.weight(.semibold))
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(Color.accentTeal.opacity(0.16), in: Capsule())
              .foregroundColor(.accentTeal)
          }
          .buttonStyle(PressableStyle(scale: 0.95))
        }
        .font(.subheadline)
        .feedRow()
      }
      if let description = model.page?.description, !description.isEmpty {
        Text(description).font(.footnote).foregroundColor(.secondary).feedRow()
      }
      if let error = model.error { ErrorBanner(message: error) { Task { await model.load() } }.feedRow() }
      VideoRows(paginator: model.videos)
    }
    .navigationTitle(current.name)
    .navigationBarTitleDisplayMode(.inline)
    .task { if model.page == nil { await model.load() } }
    // Back on the page after a while: whether they're live may have changed.
    .onAppear {
      if model.page != nil, Date().timeIntervalSince(model.loadedAt) > 60 { Task { await model.load() } }
    }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Avatar(url: current.profileImageURL, size: 64)
      VStack(alignment: .leading, spacing: 3) {
        Text(current.name).font(.title3.weight(.bold))
        if let followers = model.page?.followers {
          Text("\(Format.viewers(followers)) followers").font(.subheadline).foregroundColor(.secondary)
        }
      }
      Spacer()
      AutoRecordButton(channel: current)
      FollowButton(channel: current, font: .title2, tint: .primary)
    }
  }
}

/// A channel's videos as list rows (inside a FeedList).
struct VideoRows: View {
  @ObservedObject var paginator: Paginator<Video>

  var body: some View {
    if !paginator.items.isEmpty {
      Text("Videos").font(.headline).feedRow(top: 10, bottom: 2)
    }
    // Rows on a phone; two (or more) columns of them on a wide screen. Hold one to download it.
    // (UIKit's hold menu lifts just the video held, even with several in a list row.)
    AdaptiveFeed(items: paginator.items, tileWidth: 320, reached: { paginator.loadMoreIfNeeded(current: $0) }) { video in
      HoldMenuTile(cornerRadius: 8, menu: { VideoMenu.make(video) }) { VideoRow(video: video) }
    }
    if paginator.isLoading { ProgressView().frame(maxWidth: .infinity).padding().feedRow() }
  }
}

/// A VOD in a list: tap to watch. Shows when it's downloading or saved.
struct VideoRow: View {
  let video: Video
  @ObservedObject private var history = WatchHistory.shared
  @ObservedObject private var recordings = RecordingStore.shared

  var body: some View {
    Button {
      AppModel.shared.playing = .video(video)
    } label: {
      HStack(alignment: .top, spacing: 12) {
        RemoteImage(url: TwitchAPI.image(video.previewURL, width: 320, height: 180))
          .frame(width: 156, height: 88)
          .overlay(alignment: .bottomTrailing) {
            Text(Format.duration(video.lengthSeconds)).font(.caption2.monospacedDigit())
              .padding(.horizontal, 4).padding(.vertical, 1)
              .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3)).foregroundColor(.white)
              .padding(.horizontal, 4).padding(.bottom, 7)
          }
          .overlay(alignment: .topLeading) { saveBadge }
          .overlay(alignment: .bottom) {
            if let progress = history.progress(for: video) { WatchProgressBar(progress: progress) }
          }
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        VStack(alignment: .leading, spacing: 3) {
          Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
          Text([video.categoryName, Format.relative(video.createdAt)].compactMap { $0 }.joined(separator: " · "))
            .font(.caption).foregroundColor(.secondary).lineLimit(1)
          Text("\(Format.viewers(video.viewCount)) views").font(.caption).foregroundColor(.secondary)
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(PressableStyle(scale: 0.98))
  }

  @ViewBuilder
  private var saveBadge: some View {
    if let active = recordings.download(of: video.id) {
      let done = recordings.downloadProgress[active.id] ?? 0
      Label("\(Int(done * 100))%", systemImage: "arrow.down.circle.fill")
        .badgeStyle()
    } else if recordings.downloaded(video.id) != nil {
      Label("Saved", systemImage: "checkmark.circle.fill")
        .badgeStyle()
    }
  }
}

private extension View {
  func badgeStyle() -> some View {
    font(.caption2.weight(.semibold).monospacedDigit())
      .labelStyle(.titleAndIcon)
      .padding(.horizontal, 5).padding(.vertical, 2)
      .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
      .foregroundColor(.accentTeal)
      .padding(5)
  }
}

/// What holding a VOD offers: watch it, or save it on the iPhone to watch offline.
enum VideoMenu {
  @MainActor
  static func make(_ video: Video) -> UIMenu {
    let app = AppModel.shared
    let store = RecordingStore.shared
    var items: [UIMenuElement] = [
      UIAction(title: "Watch", image: UIImage(systemName: "play.fill")) { _ in
        Task { @MainActor in app.playing = .video(video) }
      }
    ]
    let openRecordings = UIAction(title: "Open Recordings", image: UIImage(systemName: "tray.full")) { _ in
      Task { @MainActor in app.push(.recordings) }
    }
    if let active = store.download(of: video.id) {
      let done = Int((store.downloadProgress[active.id] ?? 0) * 100)
      items.append(openRecordings)
      items.append(
        UIAction(title: "Stop download (\(done)%)", image: UIImage(systemName: "stop.circle"), attributes: .destructive) { _ in
          Task { @MainActor in store.stop(active.id) }
        })
    } else {
      if store.downloaded(video.id) != nil { items.append(openRecordings) }
      let choices = VODDownloadChoice.all.map { label in
        UIAction(
          title: label, subtitle: VODDownloadChoice.size(label, seconds: video.lengthSeconds),
          image: UIImage(systemName: label == VODDownloadChoice.audio ? "waveform" : "film")
        ) { _ in
          Task { @MainActor in store.download(video, quality: label) }
        }
      }
      items.append(
        UIMenu(
          title: store.downloaded(video.id) != nil ? "Download again" : "Download",
          subtitle: "To watch offline, in Recordings",
          image: UIImage(systemName: "arrow.down.circle"), children: choices))
    }
    return UIMenu(children: items)
  }
}
