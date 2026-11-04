// Twitch's GIF keyboard in chat (Tier 2 and 3 subs, where the channel has it on): GIPHY searched
// with the key and content rating Twitch hands out for the channel, sent through Twitch's own
// sendGifMessage. Twitch only takes GIFs found that way, at that rating, sent with the address
// GIPHY gave (it carries the search's key): others are turned away, so none are offered.

import SwiftUI

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@MainActor
final class GifKeyboardModel: ObservableObject {
  struct Gif: Identifiable, Equatable {
    let id: String
    /// What Twitch is sent: GIPHY's own address for it, untouched.
    let url: String
    /// A small moving preview for the grid.
    let preview: URL
    let aspect: CGFloat
    let title: String
  }

  enum Availability: Equatable {
    case unknown, checking, available, off, needsTier(have: Int), signedOut, failed(String)
  }

  @Published private(set) var availability: Availability = .unknown
  @Published private(set) var gifs: [Gif] = []
  @Published private(set) var loading = false
  @Published var query = ""
  @Published private(set) var notice: String?
  @Published private(set) var waitSeconds = 0
  @Published private(set) var sending = false
  private var config: TwitchAPI.GifPickerConfig?
  private var channelID = ""
  private var total = Int.max
  private var searchTask: Task<Void, Never>?
  private var generation = 0
  private var waitTimer: Timer?

  /// Asks Twitch once per channel whether GIFs can be sent there (and whether you can send them).
  func prepare(channelID: String) {
    guard channelID != self.channelID || availability == .unknown else { return }
    self.channelID = channelID
    guard TwitchAuth.shared.session != nil else {
      availability = .signedOut
      return
    }
    guard !channelID.isEmpty else { return }
    availability = .checking
    Task {
      do {
        guard let config = try await TwitchAPI.shared.gifPickerConfig(channelID: channelID) else {
          availability = .off
          return
        }
        guard config.isEnabled else {
          availability = .off
          return
        }
        self.config = config
        let tier = await TwitchAPI.shared.subscriptionTier(channelID: channelID)
        availability = tier >= 2 ? .available : .needsTier(have: tier)
        if tier >= 2 { search() }
      } catch {
        availability = .failed(error.localizedDescription)
      }
    }
  }

  /// Trending without a search; otherwise GIPHY's results. Waits a moment while typing.
  func search(debounce: Bool = false) {
    searchTask?.cancel()
    generation += 1
    gifs = []
    total = .max
    let generation = self.generation
    searchTask = Task {
      if debounce { try? await Task.sleep(nanoseconds: 350_000_000) }
      guard !Task.isCancelled, generation == self.generation else { return }
      await loadMore()
    }
  }

  func loadMoreIfNeeded(_ gif: Gif) {
    guard let index = gifs.firstIndex(of: gif), index >= gifs.count - 8 else { return }
    Task { await loadMore() }
  }

  private func loadMore() async {
    guard let config, !loading, gifs.count < total else { return }
    loading = true
    defer { loading = false }
    let generation = self.generation
    let term = query.trimmingCharacters(in: .whitespaces)
    var components = URLComponents(string: "https://api.giphy.com/v1/gifs/" + (term.isEmpty ? "trending" : "search"))!
    var items = [
      URLQueryItem(name: "api_key", value: config.apiKey),
      URLQueryItem(name: "rating", value: config.giphyRating),
      URLQueryItem(name: "limit", value: "24"),
      URLQueryItem(name: "offset", value: String(gifs.count)),
    ]
    if !term.isEmpty { items.append(URLQueryItem(name: "q", value: term)) }
    components.queryItems = items
    var data: Data?
    if let url = components.url { data = try? await URLSession.shared.data(from: url).0 }
    guard let data, let object = try? JSONSerialization.jsonObject(with: data) else {
      if gifs.isEmpty { notice = "Couldn't reach GIPHY. Try again in a moment." }
      return
    }
    guard generation == self.generation else { return }
    let json = JSONValue(object)
    total = json["pagination"]["total_count"].int ?? 0
    var seen = Set(gifs.map(\.id))
    for item in json["data"].array {
      guard let id = item["id"].string, seen.insert(id).inserted else { continue }
      let images = item["images"]
      // Twitch wants the original's address exactly as the search gave it.
      guard let original = images["original"]["url"].string, !original.isEmpty else { continue }
      let small = images["fixed_width_downsampled"]["url"].string ?? images["fixed_width"]["url"].string ?? original
      guard let preview = URL(string: small) else { continue }
      let width = Double(images["fixed_width"]["width"].string ?? "") ?? 200
      let height = Double(images["fixed_width"]["height"].string ?? "") ?? 150
      gifs.append(
        Gif(id: id, url: original, preview: preview, aspect: CGFloat(width / max(1, height)), title: item["title"].string ?? "GIF"))
    }
    notice = gifs.isEmpty ? (term.isEmpty ? "No GIFs right now." : "No GIFs found. Try another search.") : nil
  }

  /// Sends it to chat; it shows up there as everyone sees it.
  func send(_ gif: Gif, done: @escaping () -> Void) {
    guard !sending, waitSeconds == 0, !channelID.isEmpty else { return }
    sending = true
    let channelID = self.channelID
    let term = query
    Task {
      defer { sending = false }
      do {
        var result: TwitchAPI.GifSendResult
        do {
          result = try await TwitchAPI.shared.sendGif(
            channelID: channelID, gifID: gif.id, gifURL: gif.url, searchTerm: term, headers: [:])
        } catch TwitchAPIError.gql(let message) where message.localizedCaseInsensitiveContains("integrity") {
          // A website sign-in: Twitch wants proof it's its own site, as for following.
          var headers = try await TwitchIntegrity.shared.headers()
          do {
            result = try await TwitchAPI.shared.sendGif(
              channelID: channelID, gifID: gif.id, gifURL: gif.url, searchTerm: term, headers: headers)
          } catch TwitchAPIError.gql(let message) where message.localizedCaseInsensitiveContains("integrity") {
            headers = try await TwitchIntegrity.shared.headers(refresh: true)
            result = try await TwitchAPI.shared.sendGif(
              channelID: channelID, gifID: gif.id, gifURL: gif.url, searchTerm: term, headers: headers)
          }
        }
        if result.secondsUntilCanSend > 0 { startWait(result.secondsUntilCanSend) }
        if result.sent {
          ActivityLog.shared.add("Sent a GIF to chat")
          notice = nil
          // Twitch allows one every 30 seconds.
          if waitSeconds == 0 { startWait(30) }
          done()
          return
        }
        ActivityLog.shared.add("GIF not sent: \(result.error ?? "no error, no message") (wait \(result.secondsUntilCanSend) s)")
        switch result.error {
        case "TEMPORARILY_UNAVAILABLE": notice = "GIFs are unavailable right now. Try again later."
        case .some(let error): notice = "Twitch didn't take that GIF (\(error.lowercased().replacingOccurrences(of: "_", with: " ")))."
        case .none: notice = result.secondsUntilCanSend > 0 ? "Wait a moment before the next GIF." : "Couldn't tell whether it was sent: check chat."
        }
      } catch {
        notice = "Couldn't send the GIF: \(error.localizedDescription)"
        ActivityLog.shared.add("GIF not sent: \(error.localizedDescription)")
      }
    }
  }

  private func startWait(_ seconds: Int) {
    waitSeconds = seconds
    waitTimer?.invalidate()
    waitTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
      Task { @MainActor in
        guard let self else { return timer.invalidate() }
        self.waitSeconds = max(0, self.waitSeconds - 1)
        if self.waitSeconds == 0 { timer.invalidate() }
      }
    }
  }
}

/// The GIF tab of the emote picker.
struct GifKeyboard: View {
  @ObservedObject var model: GifKeyboardModel
  var sent: () -> Void
  private let columns = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]

  var body: some View {
    VStack(spacing: 6) {
      switch model.availability {
      case .available:
        HStack(spacing: 8) {
          HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Search GIPHY", text: $model.query)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .submitLabel(.search)
              .onSubmit { model.search() }
          }
          .padding(.horizontal, 10).padding(.vertical, 7)
          .background(Color.white.opacity(0.08), in: Capsule())
          if model.waitSeconds > 0 {
            Text("\(model.waitSeconds)s").font(.caption.monospacedDigit().weight(.semibold)).foregroundColor(.secondary)
              .accessibilityLabel("Next GIF in \(model.waitSeconds) seconds")
          }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .onChange(of: model.query) { _ in model.search(debounce: true) }
        if let notice = model.notice {
          Text(notice).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 12)
        }
        ScrollView {
          LazyVGrid(columns: columns, spacing: 4) {
            ForEach(model.gifs) { gif in
              Button {
                model.send(gif, done: sent)
              } label: {
                CachedImage(url: gif.preview, maxPixels: 300, contentMode: .scaleAspectFill, placeholder: nil)
                  .frame(maxWidth: .infinity)
                  .frame(height: 86)
                  .background(Color.white.opacity(0.06))
                  .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                  .contentShape(Rectangle())
              }
              .buttonStyle(PressableStyle(scale: 0.92))
              .disabled(model.sending || model.waitSeconds > 0)
              .opacity(model.waitSeconds > 0 ? 0.5 : 1)
              .accessibilityLabel(gif.title)
              .onAppear { model.loadMoreIfNeeded(gif) }
            }
          }
          .padding(.horizontal, 8)
          if model.loading { ProgressView().padding(8) }
          Text("Powered by GIPHY · GIFs must follow Twitch's Community Guidelines")
            .font(.caption2).foregroundColor(.secondary).padding(.vertical, 8)
        }
      case .unknown, .checking:
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      case .off:
        message("GIFs are off in this channel.")
      case .needsTier(let have):
        message("GIFs are for Tier 2 and Tier 3 subscribers here. You have \(have == 0 ? "no sub" : "a Tier \(have) sub").")
      case .signedOut:
        message("Sign in with Twitch to send GIFs.")
      case .failed(let error):
        message("Couldn't check GIFs here: \(error)")
      }
    }
  }

  private func message(_ text: String) -> some View {
    Text(text).font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center).padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
