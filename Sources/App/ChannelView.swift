import SwiftUI

@MainActor
final class ChannelModel: ObservableObject {
  @Published var page: ChannelPage?
  @Published var error: String?
  @Published var isLoading = false
  let videos: Paginator<Video>
  let login: String

  nonisolated init(login: String) {
    self.login = login
    videos = Paginator { try await TwitchAPI.shared.videos(login: login, after: $0) }
  }

  func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      page = try await TwitchAPI.shared.channelPage(login: login)
      if page == nil { error = "Channel not found." }
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
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        if let stream = model.page?.stream {
          VStack(alignment: .leading, spacing: 6) {
            Text("Live now").font(.headline)
            StreamCard(stream: stream)
          }
        } else if model.page != nil {
          HStack {
            Image(systemName: "moon.zzz").foregroundColor(.secondary)
            Text(model.page?.lastBroadcast.map { "Offline · last live \(Format.relative($0))" } ?? "Offline")
              .foregroundColor(.secondary)
          }
          .font(.subheadline)
        }
        if let description = model.page?.description, !description.isEmpty {
          Text(description).font(.footnote).foregroundColor(.secondary)
        }
        if let error = model.error { ErrorBanner(message: error) { Task { await model.load() } } }
        VideosSection(paginator: model.videos)
      }
      .padding()
    }
    .navigationTitle(current.name)
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await model.load() }
    .task { if model.page == nil { await model.load() } }
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
      Button {
        favorites.toggle(current)
      } label: {
        Image(systemName: favorites.contains(current) ? "heart.fill" : "heart")
          .font(.title2)
          .foregroundColor(favorites.contains(current) ? .liveRed : .primary)
      }
      .accessibilityLabel(favorites.contains(current) ? "Unfollow" : "Follow")
    }
  }
}

struct VideosSection: View {
  @ObservedObject var paginator: Paginator<Video>
  @EnvironmentObject private var app: AppModel

  var body: some View {
    if !paginator.items.isEmpty {
      Text("Videos").font(.headline).padding(.top, 6)
    }
    LazyVStack(alignment: .leading, spacing: 14) {
      ForEach(paginator.items) { video in
        Button {
          app.playing = .video(video)
        } label: {
          HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: TwitchAPI.image(video.previewURL, width: 320, height: 180))
              .frame(width: 144, height: 81)
              .overlay(alignment: .bottomTrailing) {
                Text(Format.duration(video.lengthSeconds)).font(.caption2.monospacedDigit())
                  .padding(.horizontal, 4).padding(.vertical, 1)
                  .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3)).foregroundColor(.white).padding(4)
              }
              .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
              Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(2)
              Text([video.categoryName, Format.relative(video.createdAt)].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundColor(.secondary).lineLimit(1)
              Text("\(Format.viewers(video.viewCount)) views").font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { paginator.loadMoreIfNeeded(current: video) }
      }
      if paginator.isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
    }
  }
}
