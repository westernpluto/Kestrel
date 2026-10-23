import SwiftUI

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
        HStack {
          Image(systemName: "moon.zzz").foregroundColor(.secondary)
          Text(model.page?.lastBroadcast.map { "Offline · last live \(Format.relative($0))" } ?? "Offline")
            .foregroundColor(.secondary)
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
      FollowButton(channel: current, font: .title2, tint: .primary)
    }
  }
}

/// A channel's videos as list rows (inside a FeedList).
struct VideoRows: View {
  @ObservedObject var paginator: Paginator<Video>
  @EnvironmentObject private var app: AppModel
  @ObservedObject private var history = WatchHistory.shared

  var body: some View {
    if !paginator.items.isEmpty {
      Text("Videos").font(.headline).feedRow(top: 10, bottom: 2)
    }
    ForEach(paginator.items) { video in
      Button {
        app.playing = .video(video)
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
      .feedRow(top: 7, bottom: 7)
      .onAppear { paginator.loadMoreIfNeeded(current: video) }
    }
    if paginator.isLoading { ProgressView().frame(maxWidth: .infinity).padding().feedRow() }
  }
}
