import AVKit
import SwiftUI

struct VideoPlayerView: UIViewControllerRepresentable {
  let player: AVPlayer

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.player = player
    controller.allowsPictureInPicturePlayback = true
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    controller.updatesNowPlayingInfoCenter = true
    controller.entersFullScreenWhenPlaybackBegins = false
    controller.exitsFullScreenWhenPlaybackEnds = false
    controller.videoGravity = .resizeAspect
    controller.view.backgroundColor = .black
    controller.delegate = context.coordinator
    context.coordinator.controller = controller
    context.coordinator.player = player
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
    if controller.player !== player, !context.coordinator.detached { controller.player = player }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
    weak var controller: AVPlayerViewController?
    weak var player: AVPlayer?
    var pictureInPicture = false
    var detached = false
    private var tokens: [NSObjectProtocol] = []

    override init() {
      super.init()
      let center = NotificationCenter.default
      tokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
        self?.enteredBackground()
      })
      tokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
        self?.enteringForeground()
      })
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

    /// Detaching the player from the view keeps the audio going in the background.
    private func enteredBackground() {
      guard !pictureInPicture, AppSettings.shared.backgroundAudio, let controller else { return }
      detached = true
      controller.player = nil
    }

    private func enteringForeground() {
      guard detached else { return }
      detached = false
      controller?.player = player
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
      pictureInPicture = true
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
      pictureInPicture = false
    }

    func playerViewController(
      _ playerViewController: AVPlayerViewController,
      restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
      completionHandler(true)
    }
  }
}

struct PlayerScreen: View {
  let target: PlaybackTarget
  @StateObject private var model: PlayerModel
  @StateObject private var chat: ChatController
  @EnvironmentObject private var favorites: FavoritesStore
  @EnvironmentObject private var settings: AppSettings
  @Environment(\.dismiss) private var dismiss
  @State private var showLandscapeChat = false

  init(target: PlaybackTarget) {
    self.target = target
    _model = StateObject(wrappedValue: PlayerModel(target: target))
    let channel: Channel
    switch target {
    case .live(let c): channel = c
    case .video(let video): channel = video.owner ?? Channel(id: "", login: "", displayName: "", profileImageURL: nil)
    }
    _chat = StateObject(wrappedValue: ChatController(channel: channel))
  }

  private var showsChat: Bool { model.isLive && settings.chatEnabled }
  private var showsEngineMenu: Bool { model.isLive && PlayerEngine.available.count > 1 }

  var body: some View {
    GeometryReader { geometry in
      let landscape = geometry.size.width > geometry.size.height
      ZStack {
        Color.black.ignoresSafeArea()
        if landscape {
          // Our buttons live beside the video so they never cover the player's own controls.
          HStack(spacing: 0) {
            video.ignoresSafeArea(edges: [.vertical, .leading])
            VStack(spacing: 0) {
              if showLandscapeChat && showsChat {
                HStack(spacing: 4) {
                  closeButton
                  chatToggle
                  Spacer()
                  if showsEngineMenu { engineMenu }
                }
                .padding(.vertical, 4)
                ChatView(chat: chat)
              } else {
                closeButton.padding(.top, 6)
                if showsChat { chatToggle }
                if showsEngineMenu { engineMenu }
                Spacer()
              }
            }
            .frame(width: showLandscapeChat && showsChat ? min(340, geometry.size.width * 0.36) : 52)
            .background(Color(white: 0.06))
          }
        } else {
          VStack(spacing: 0) {
            HStack {
              closeButton
              Spacer()
              Text(model.isLive ? (model.engine == .lowLatency ? "Live · Low latency" : "Live") : "Video")
                .font(.footnote.weight(.semibold)).foregroundColor(.secondary)
              Spacer()
              if showsEngineMenu { engineMenu } else { Color.clear.frame(width: 40, height: 40) }
            }
            .padding(.horizontal, 6)
            video.aspectRatio(16 / 9, contentMode: .fit)
            infoBar
            Divider().background(Color.white.opacity(0.1))
            if showsChat {
              ChatView(chat: chat).background(Color(white: 0.06))
            } else {
              vodDetails
            }
          }
        }
      }
    }
    .preferredColorScheme(.dark)
    .task {
      if showsChat { chat.start() }
      await model.start()
    }
    .onDisappear {
      model.stop()
      chat.stop()
    }
  }

  // MARK: Video area

  private var video: some View {
    ZStack {
      #if canImport(AmazonIVSPlayer)
        if let controller = model.lowLatency {
          LowLatencySurface(controller: controller)
        } else {
          VideoPlayerView(player: model.player)
        }
      #else
        VideoPlayerView(player: model.player)
      #endif
      overlays
    }
  }

  private var engineMenu: some View {
    Menu {
      ForEach(PlayerEngine.available) { option in
        Button {
          model.setEngine(option)
        } label: {
          if option == model.engine { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
        }
      }
    } label: {
      Image(systemName: "rectangle.on.rectangle")
        .font(.system(size: 16, weight: .semibold))
        .frame(width: 40, height: 40)
        .foregroundColor(.white)
    }
    .accessibilityLabel("Choose player")
  }

  private var closeButton: some View {
    Button {
      dismiss()
    } label: {
      Image(systemName: "chevron.down")
        .font(.system(size: 17, weight: .bold))
        .frame(width: 40, height: 40)
        .foregroundColor(.white)
    }
    .accessibilityLabel("Close player")
  }

  private var chatToggle: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.2)) { showLandscapeChat.toggle() }
    } label: {
      Image(systemName: showLandscapeChat ? "bubble.left.fill" : "bubble.left")
        .font(.system(size: 16, weight: .semibold))
        .frame(width: 40, height: 40)
        .foregroundColor(.white)
    }
    .accessibilityLabel(showLandscapeChat ? "Hide chat" : "Show chat")
  }

  @ViewBuilder
  private var overlays: some View {
    switch model.phase {
    case .loading:
      ProgressView().tint(.white)
    case .offline:
      statusCard(icon: "moon.zzz.fill", title: "Offline", message: "\(model.channel?.name ?? "This channel") isn't live right now.")
    case .failed(let message):
      VStack(spacing: 12) {
        statusCard(icon: "exclamationmark.triangle.fill", title: "Couldn't play", message: message)
        Button("Retry") { model.retry() }.buttonStyle(.borderedProminent).tint(.accentTeal)
      }
    case .playing:
      if model.engine == .lowLatency, model.isBuffering, !model.coveringAd {
        ProgressView().tint(.white).allowsHitTesting(false)
      }
      if model.coveringAd {
        ZStack {
          Color.black
          VStack(spacing: 8) {
            Image(systemName: "eye.slash.fill").font(.title2)
            Text("Ad break").font(.headline)
            Text("No ad-free copy was available, so the ad is hidden and muted. The stream resumes on its own.")
              .font(.caption).multilineTextAlignment(.center).foregroundColor(.secondary).padding(.horizontal, 30)
          }
          .foregroundColor(.white)
        }
      }
    }
  }

  private func statusCard(icon: String, title: String, message: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: icon).font(.title)
      Text(title).font(.headline)
      Text(message).font(.footnote).multilineTextAlignment(.center).foregroundColor(.secondary)
    }
    .foregroundColor(.white)
    .padding(24)
  }

  // MARK: Info bar

  private var infoBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        Avatar(url: model.channel?.profileImageURL, size: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
          HStack(spacing: 6) {
            Text(model.channel?.name ?? "").font(.footnote).foregroundColor(.secondary)
            if let category = model.stream?.category?.name {
              Text("· \(category)").font(.footnote).foregroundColor(.accentTeal).lineLimit(1)
            }
          }
        }
        Spacer(minLength: 4)
        if let channel = model.channel, !channel.id.isEmpty {
          Button {
            favorites.toggle(channel)
          } label: {
            Image(systemName: favorites.contains(channel) ? "heart.fill" : "heart")
              .font(.title3)
              .foregroundColor(favorites.contains(channel) ? .liveRed : .white)
          }
        }
      }
      HStack(spacing: 10) {
        if model.isLive, let viewers = model.stream?.viewers { LiveBadge(viewers: viewers) }
        if let uptime = Format.uptime(since: model.stream?.startedAt) {
          Label(uptime, systemImage: "clock").font(.caption.monospacedDigit()).foregroundColor(.secondary)
        }
        if model.isLive, let latency = model.latency {
          Button {
            model.goLive()
          } label: {
            Label(String(format: "%.1fs", latency), systemImage: "bolt.fill")
              .font(.caption.monospacedDigit())
              .foregroundColor(latency < 6 ? .accentTeal : .secondary)
          }
          .accessibilityLabel(String(format: "%.1f seconds behind live. Jump to live", latency))
        }
        adPill
        Spacer()
        if model.qualities.count > 1 {
          Menu {
            ForEach(model.qualities) { quality in
              Button {
                model.selectQuality(quality)
              } label: {
                if quality.id == model.selectedQuality { Label(quality.label, systemImage: "checkmark") } else { Text(quality.label) }
              }
            }
          } label: {
            Label(currentQualityLabel, systemImage: "slider.horizontal.3")
              .font(.caption.weight(.semibold))
              .padding(.horizontal, 8)
              .padding(.vertical, 5)
              .background(Color.white.opacity(0.12), in: Capsule())
          }
        }
      }
    }
    .padding(12)
    .foregroundColor(.white)
  }

  @ViewBuilder
  private var adPill: some View {
    switch model.adState {
    case .none:
      EmptyView()
    case .skipped:
      Label("Ad skipped", systemImage: "checkmark.shield.fill").font(.caption2.weight(.semibold)).foregroundColor(.accentTeal)
    case .searching:
      Label("Ad · skipping", systemImage: "shield.lefthalf.filled").font(.caption2.weight(.semibold)).foregroundColor(.orange)
    case .replaced:
      Label("Ad blocked", systemImage: "checkmark.shield.fill").font(.caption2.weight(.semibold)).foregroundColor(.accentTeal)
    case .covering:
      Label("Ad hidden", systemImage: "eye.slash.fill").font(.caption2.weight(.semibold)).foregroundColor(.orange)
    }
  }

  private var currentQualityLabel: String {
    model.qualities.first { $0.id == model.selectedQuality }?.label ?? "Auto"
  }

  private var title: String {
    switch target {
    case .live: return model.stream?.title ?? model.channel?.name ?? ""
    case .video(let video): return video.title
    }
  }

  @ViewBuilder
  private var vodDetails: some View {
    if case .video(let video) = target {
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          Text(video.title).font(.headline)
          Text([video.categoryName, Format.relative(video.createdAt), "\(Format.viewers(video.viewCount)) views"].compactMap { $0 }.joined(separator: " · "))
            .font(.footnote).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
    } else {
      Spacer()
    }
  }
}
