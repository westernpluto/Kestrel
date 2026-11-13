// Twitch's GIF keyboard in chat (Tier 2 and 3 subs, where the channel has it on): GIPHY searched
// with the key and content rating Twitch hands out for the channel, sent through Twitch's own
// sendGifMessage. Twitch only takes GIFs found that way, at that rating, sent with the address
// GIPHY gave (it carries the search's key): others are turned away, so none are offered.
//
// Even so, Twitch turns some away with a bare "ERROR" (no reason given), and which can't be told
// beforehand: so each channel remembers (GifMemory) the GIFs that went through there, offered first
// as sure to send, and hides the ones Twitch turned away there. What Twitch said, and the GIF's
// size, rating and place in the results, go in the Activity log, to learn what it objects to.

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
    /// What it was found with (Twitch is sent the same).
    var term: String = ""
    /// For the Activity log: the original's size and dimensions, its rating, where it was in the
    /// results.
    var bytes: Int? = nil
    var width: Int? = nil
    var height: Int? = nil
    var rating: String? = nil
    var position: Int? = nil

    var details: String {
      var parts: [String] = []
      if let bytes { parts.append(String(format: "%.1f MB", Double(bytes) / 1_000_000)) }
      if let width, let height { parts.append("\(width)x\(height)") }
      if let rating { parts.append("rated \(rating)") }
      if let position { parts.append("#\(position + 1) in " + (term.isEmpty ? "trending" : "\"\(term)\"")) }
      return parts.isEmpty ? "sent here before" : parts.joined(separator: ", ")
    }

    var remembered: GifMemory.Sent {
      GifMemory.Sent(id: id, url: url, preview: preview.absoluteString, aspect: Double(aspect), title: title, term: term)
    }

    init(id: String, url: String, preview: URL, aspect: CGFloat, title: String) {
      self.id = id
      self.url = url
      self.preview = preview
      self.aspect = aspect
      self.title = title
    }

    init?(_ sent: GifMemory.Sent) {
      guard let preview = URL(string: sent.preview) else { return nil }
      self.init(id: sent.id, url: sent.url, preview: preview, aspect: CGFloat(sent.aspect), title: sent.title)
      term = sent.term
    }
  }

  enum Availability: Equatable {
    case unknown, checking, available, off, needsTier(have: Int), signedOut, failed(String)
  }

  @Published private(set) var availability: Availability = .unknown
  @Published private(set) var gifs: [Gif] = []
  /// GIFs that went through in this channel, newest first: sure to send.
  @Published private(set) var sentHere: [Gif] = []
  private static let memoryKey = "kestrel.gifMemory"
  private var memory: GifMemory = {
    guard let data = UserDefaults.standard.data(forKey: memoryKey), let saved = try? JSONDecoder().decode(GifMemory.self, from: data)
    else { return GifMemory() }
    return saved
  }()
  @Published private(set) var loading = false
  @Published var query = ""
  @Published private(set) var notice: String?
  @Published private(set) var waitSeconds = 0
  @Published private(set) var sending = false
  private var config: TwitchAPI.GifPickerConfig?
  private var channelID = ""
  private var total = Int.max
  /// GIPHY's offset for the next page (past what was hidden, not just what's shown).
  private var nextOffset = 0
  private var searchTask: Task<Void, Never>?
  private var generation = 0
  private var waitTimer: Timer?

  /// Asks Twitch once per channel whether GIFs can be sent there (and whether you can send them).
  func prepare(channelID: String) {
    guard channelID != self.channelID || availability == .unknown else { return }
    self.channelID = channelID
    sentHere = memory.sentHere(channelID).compactMap(Gif.init)
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
    nextOffset = 0
    hiddenPages = 0
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
    guard let config, !loading, nextOffset < total else { return }
    loading = true
    defer { loading = false }
    let generation = self.generation
    let term = query.trimmingCharacters(in: .whitespaces)
    var components = URLComponents(string: "https://api.giphy.com/v1/gifs/" + (term.isEmpty ? "trending" : "search"))!
    var items = [
      URLQueryItem(name: "api_key", value: config.apiKey),
      URLQueryItem(name: "rating", value: config.giphyRating),
      URLQueryItem(name: "limit", value: "24"),
      URLQueryItem(name: "offset", value: String(nextOffset)),
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
    let shownBefore = gifs.count
    var seen = Set(gifs.map(\.id))
    // (Those already under Sent here before aren't shown twice with no search.)
    if term.isEmpty { seen.formUnion(sentHere.map(\.id)) }
    var position = json["pagination"]["offset"].int ?? nextOffset
    nextOffset = position + max(1, json["data"].array.count)
    for item in json["data"].array {
      defer { position += 1 }
      guard let id = item["id"].string, seen.insert(id).inserted else { continue }
      // Turned away in this channel before: not offered again.
      guard !memory.isRefused(id, channel: channelID) else { continue }
      let images = item["images"]
      // Twitch wants the original's address exactly as the search gave it.
      guard let original = images["original"]["url"].string, !original.isEmpty else { continue }
      let small = images["fixed_width_downsampled"]["url"].string ?? images["fixed_width"]["url"].string ?? original
      guard let preview = URL(string: small) else { continue }
      let width = Double(images["fixed_width"]["width"].string ?? "") ?? 200
      let height = Double(images["fixed_width"]["height"].string ?? "") ?? 150
      var gif = Gif(id: id, url: original, preview: preview, aspect: CGFloat(width / max(1, height)), title: item["title"].string ?? "GIF")
      gif.term = term
      gif.bytes = images["original"]["size"].string.flatMap(Int.init)
      gif.width = images["original"]["width"].string.flatMap(Int.init)
      gif.height = images["original"]["height"].string.flatMap(Int.init)
      gif.rating = item["rating"].string
      gif.position = position
      gifs.append(gif)
    }
    // A page that was all hidden shows nothing new to scroll to (which asks for the next): the
    // next page is asked for straight away, a few at most.
    if gifs.count == shownBefore, nextOffset < total, hiddenPages < 3 {
      hiddenPages += 1
      Task { [weak self] in await self?.loadMore() }
      return
    }
    hiddenPages = 0
    notice = gifs.isEmpty ? (term.isEmpty ? "No GIFs right now." : "No GIFs found. Try another search.") : nil
  }

  private var hiddenPages = 0

  /// Sends it to chat; it shows up there as everyone sees it.
  func send(_ gif: Gif, done: @escaping () -> Void) {
    guard !sending, waitSeconds == 0, !channelID.isEmpty else { return }
    sending = true
    let channelID = self.channelID
    // The search it was found with (a GIF from Sent here before: the one it was found with then).
    let term = gif.term
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
          ActivityLog.shared.add("Sent a GIF to chat (\(gif.details))")
          remember(sent: gif, channel: channelID)
          notice = nil
          // Twitch allows one every 30 seconds.
          if waitSeconds == 0 { startWait(30) }
          done()
          return
        }
        ActivityLog.shared.add(
          "GIF not sent: \(result.error ?? "no error, no message") (wait \(result.secondsUntilCanSend) s) for \"\(gif.title)\" (\(gif.details)); Twitch said: \(result.raw)")
        switch result.error {
        case "TEMPORARILY_UNAVAILABLE": notice = "GIFs are unavailable right now. Try again later."
        case .some(let error):
          // Twitch gives no reason; this one isn't offered here again.
          remember(refused: gif, channel: channelID)
          let reason = error == "ERROR" ? "" : " (\(error.lowercased().replacingOccurrences(of: "_", with: " ")))"
          notice = "Twitch didn't take that GIF here\(reason), so it's hidden now."
            + (sentHere.isEmpty ? "" : " The ones under Sent here before are sure to go through.")
        case .none: notice = result.secondsUntilCanSend > 0 ? "Wait a moment before the next GIF." : "Couldn't tell whether it was sent: check chat."
        }
      } catch {
        notice = "Couldn't send the GIF: \(error.localizedDescription)"
        ActivityLog.shared.add("GIF not sent: \(error.localizedDescription)")
      }
    }
  }

  private func remember(sent gif: Gif, channel: String) {
    memory.noteSent(gif.remembered, channel: channel)
    saveMemory()
    if channel == channelID { sentHere = memory.sentHere(channel).compactMap(Gif.init) }
  }

  private func remember(refused gif: Gif, channel: String) {
    memory.noteRefused(gif.id, channel: channel)
    saveMemory()
    guard channel == channelID, memory.isRefused(gif.id, channel: channel) else { return }
    gifs.removeAll { $0.id == gif.id }
  }

  private func saveMemory() {
    if let data = try? JSONEncoder().encode(memory) { UserDefaults.standard.set(data, forKey: Self.memoryKey) }
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
          // With no search: the ones that went through in this channel first (sure to send).
          let searching = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
          if !searching, !model.sentHere.isEmpty {
            sectionTitle("Sent here before")
            LazyVGrid(columns: columns, spacing: 4) {
              ForEach(model.sentHere) { gif in cell(gif, loadsMore: false) }
            }
            .padding(.horizontal, 8)
            sectionTitle("Trending")
          }
          LazyVGrid(columns: columns, spacing: 4) {
            ForEach(model.gifs) { gif in cell(gif, loadsMore: true) }
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

  private func cell(_ gif: GifKeyboardModel.Gif, loadsMore: Bool) -> some View {
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
    .onAppear { if loadsMore { model.loadMoreIfNeeded(gif) } }
  }

  private func sectionTitle(_ text: String) -> some View {
    Text(text).font(.caption.weight(.semibold)).foregroundColor(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12).padding(.top, 6)
  }

  private func message(_ text: String) -> some View {
    Text(text).font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center).padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
