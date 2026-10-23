import Foundation
import SwiftUI
import UIKit

/// Twitch chat over WebSocket IRC: as yourself when signed in (so you can send), else read-only.
@MainActor
final class ChatController: ObservableObject {
  enum Status: Equatable { case connecting, connected, disconnected(String) }

  @Published private(set) var status: Status = .connecting
  /// Signed in and in the room: messages can be sent.
  @Published private(set) var canSend = false
  /// Room rules worth showing (slow mode, followers-only, …).
  @Published private(set) var roomRules: String?
  private(set) var messages: [ChatMessage] = []
  private(set) var thirdParty: [String: URL] = [:]
  private(set) var badges: [String: Badge] = [:]
  /// Called with `true` when everything should be re-rendered (emotes/badges loaded).
  var onUpdate: ((_ fullReload: Bool) -> Void)?

  let channel: Channel
  private var socket: URLSessionWebSocketTask?
  private var pending: [ChatMessage] = []
  private var flushScheduled = false
  private var running = false
  private var attempt = 0
  private let maxMessages = 250
  private var userState: [String: String] = [:]
  private var room: [String: String] = [:]
  private var signedInLogin: String?
  private var authRefused = false

  nonisolated init(channel: Channel) {
    self.channel = channel
  }

  var ownLogin: String? { signedInLogin }

  func start() {
    guard !running else { return }
    running = true
    let channel = self.channel
    Task {
      let http = URLSessionHTTPClient(timeout: 10)
      async let history = ThirdPartyEmotes.recentMessages(login: channel.login, http: http)
      async let badgeMap = TwitchAPI.shared.badges(channelID: channel.id)
      let emotes = await ThirdPartyEmotes.load(channelID: channel.id, http: http)
      let (recent, loadedBadges) = await (history, badgeMap)
      thirdParty = emotes
      badges = loadedBadges
      let old = recent.compactMap(ChatMessage.init(irc:)).filter { $0.kind != .notice }
      messages = Array((old + messages).suffix(maxMessages))
      onUpdate?(true)
    }
    connect()
  }

  func stop() {
    running = false
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
  }

  /// After signing in or out.
  func reconnect() {
    guard running else { return }
    authRefused = false
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    connect()
  }

  func send(_ raw: String) {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard canSend, !text.isEmpty, let socket, let login = signedInLogin else { return }
    let line: String
    if text.hasPrefix("/me ") {
      line = "PRIVMSG #\(channel.login.lowercased()) :\u{1}ACTION \(text.dropFirst(4))\u{1}"
    } else {
      line = "PRIVMSG #\(channel.login.lowercased()) :\(text)"
    }
    socket.send(.string(line)) { [weak self] error in
      guard let error, let chat = self else { return }
      Task { @MainActor in chat.enqueue(ChatMessage(notice: "Couldn't send: \(error.localizedDescription)")) }
    }
    enqueue(ChatMessage(sent: text, userState: userState, login: login))
  }

  private func connect() {
    guard running else { return }
    status = .connecting
    canSend = false
    let task = URLSession.shared.webSocketTask(with: URL(string: "wss://irc-ws.chat.twitch.tv:443")!)
    socket = task
    task.resume()
    var lines = ["CAP REQ :twitch.tv/tags twitch.tv/commands"]
    if !authRefused, let session = TwitchAuth.shared.session {
      signedInLogin = session.login.lowercased()
      lines += ["PASS oauth:\(session.token)", "NICK \(session.login.lowercased())"]
    } else {
      signedInLogin = nil
      lines += ["PASS SCHMOOPIIE", "NICK justinfan\(Int.random(in: 10000...99999))"]
    }
    lines.append("JOIN #\(channel.login.lowercased())")
    for line in lines { task.send(.string(line)) { _ in } }
    receive(task)
  }

  private func receive(_ task: URLSessionWebSocketTask) {
    task.receive { [weak self] result in
      Task { @MainActor in
        guard let self, self.socket === task else { return }
        switch result {
        case .failure(let error):
          self.reconnect(after: error)
        case .success(let message):
          switch message {
          case .string(let text): self.handle(text)
          case .data(let data): self.handle(String(decoding: data, as: UTF8.self))
          @unknown default: break
          }
          self.receive(task)
        }
      }
    }
  }

  private func reconnect(after error: Error) {
    socket = nil
    canSend = false
    guard running else { return }
    attempt += 1
    status = .disconnected("Reconnecting…")
    let delay = min(15.0, pow(2, Double(min(attempt, 4))))
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
  }

  private func handle(_ text: String) {
    for line in text.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" }) {
      guard let irc = IRCMessage.parse(String(line)) else { continue }
      switch irc.command {
      case "PING":
        socket?.send(.string("PONG :\(irc.trailing ?? "tmi.twitch.tv")")) { _ in }
      case "001":
        attempt = 0
      case "366":
        status = .connected
      case "ROOMSTATE":
        status = .connected
        room.merge(irc.tags) { _, new in new }
        roomRules = Self.describe(room)
      case "USERSTATE":
        userState = irc.tags
        canSend = signedInLogin != nil
      case "CLEARMSG":
        if let id = irc.tags["target-msg-id"] { markDeleted { $0.id == id } }
      case "CLEARCHAT":
        if irc.params.count > 1, let login = irc.trailing?.lowercased() {
          markDeleted { $0.login.lowercased() == login }
        }
      case "RECONNECT":
        socket?.cancel(with: .goingAway, reason: nil)
      case "NOTICE":
        let message = irc.trailing ?? ""
        if message.localizedCaseInsensitiveContains("authentication failed")
          || message.localizedCaseInsensitiveContains("improperly formatted auth")
        {
          // The token doesn't work for chat: read as a guest instead of not at all.
          authRefused = true
          enqueue(ChatMessage(notice: "Twitch didn't accept your sign-in for chat, so it's read-only. Sign in again in Settings."))
          socket?.cancel(with: .goingAway, reason: nil)
          socket = nil
          connect()
          return
        }
        if let notice = ChatMessage(irc: irc) { enqueue(notice) }
      default:
        if let message = ChatMessage(irc: irc) { enqueue(message) }
      }
    }
  }

  static func describe(_ room: [String: String]) -> String? {
    var rules: [String] = []
    if let slow = room["slow"].flatMap(Int.init), slow > 0 { rules.append("Slow mode \(slow)s") }
    if let followers = room["followers-only"].flatMap(Int.init), followers >= 0 {
      rules.append(followers == 0 ? "Followers-only" : "Followers-only (\(followers) min)")
    }
    if room["subs-only"] == "1" { rules.append("Subscribers-only") }
    if room["emote-only"] == "1" { rules.append("Emote-only") }
    return rules.isEmpty ? nil : rules.joined(separator: " · ")
  }

  private func markDeleted(_ predicate: (ChatMessage) -> Bool) {
    var changed = false
    for i in messages.indices where predicate(messages[i]) && !messages[i].isDeleted {
      messages[i].isDeleted = true
      changed = true
    }
    if changed { onUpdate?(true) }
  }

  private func enqueue(_ message: ChatMessage) {
    pending.append(message)
    guard !flushScheduled else { return }
    flushScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.flush() }
  }

  private func flush() {
    flushScheduled = false
    guard !pending.isEmpty else { return }
    messages.append(contentsOf: pending)
    pending.removeAll()
    if messages.count > maxMessages { messages.removeFirst(messages.count - maxMessages) }
    onUpdate?(false)
  }
}

// MARK: - Rendering

/// A message laid out as text, with image slots (badges, emotes) drawn by image views on top.
struct RenderedMessage {
  struct Slot {
    var range: NSRange
    var url: URL
    var size: CGSize
  }
  var text: NSAttributedString
  var slots: [Slot]
  var highlighted: Bool
}

enum ChatRenderer {
  static let accent = UIColor(red: 0.57, green: 0.38, blue: 1.0, alpha: 1)

  static func color(_ hex: String?, fallbackSeed: String) -> UIColor {
    var value: UInt64 = 0
    if let hex, hex.hasPrefix("#"), Scanner(string: String(hex.dropFirst())).scanHexInt64(&value) {
      var r = CGFloat((value >> 16) & 0xFF) / 255, g = CGFloat((value >> 8) & 0xFF) / 255, b = CGFloat(value & 0xFF) / 255
      let luminance = 0.299 * r + 0.587 * g + 0.114 * b
      if luminance < 0.45 {  // too dark on a dark background: lighten
        let boost = 0.45 - luminance
        r = min(1, r + boost)
        g = min(1, g + boost)
        b = min(1, b + boost)
      }
      return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
    let palette: [UIColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple, .systemPink]
    let seed = fallbackSeed.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value }
    return palette[Int(seed % UInt32(palette.count))]
  }

  /// An invisible placeholder the size of the image; an image view is placed over it.
  private static func slot(_ url: URL, height: CGFloat, font: UIFont, into text: NSMutableAttributedString, slots: inout [RenderedMessage.Slot]) {
    let image = ImagePipeline.shared.cached(url, maxPixels: 112)
    if image == nil { ImagePipeline.shared.load(url, maxPixels: 112) { _ in ChatImageEvents.imageArrived() } }
    let ratio = image.map { $0.size.height > 0 ? min(4, $0.size.width / $0.size.height) : 1 } ?? 1
    let size = CGSize(width: (height * ratio).rounded(), height: height)
    let attachment = NSTextAttachment()
    attachment.image = UIImage()
    attachment.bounds = CGRect(x: 0, y: (font.capHeight - height) / 2, width: size.width, height: size.height)
    slots.append(RenderedMessage.Slot(range: NSRange(location: text.length, length: 1), url: url, size: size))
    text.append(NSAttributedString(attachment: attachment))
  }

  static func render(_ message: ChatMessage, badges: [String: Badge], thirdParty: [String: URL], fontSize: CGFloat, me: String?)
    -> RenderedMessage
  {
    let font = UIFont.systemFont(ofSize: fontSize)
    let bold = UIFont.systemFont(ofSize: fontSize, weight: .bold)
    let text = NSMutableAttributedString()
    var slots: [RenderedMessage.Slot] = []
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 2
    let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]

    if message.kind == .notice {
      text.append(NSAttributedString(string: message.text, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: paragraph]))
      return RenderedMessage(text: text, slots: [], highlighted: false)
    }
    if let system = message.systemText {
      text.append(NSAttributedString(string: system, attributes: [.font: bold, .foregroundColor: accent, .paragraphStyle: paragraph]))
      if message.text.isEmpty { return RenderedMessage(text: text, slots: [], highlighted: true) }
      text.append(NSAttributedString(string: "\n", attributes: plain))
    }
    for badge in message.badges {
      guard let info = badges[badge], let url = URL(string: info.imageURL) else { continue }
      slot(url, height: (fontSize + 3).rounded(), font: font, into: text, slots: &slots)
      text.append(NSAttributedString(string: " ", attributes: plain))
    }
    let nameColor = color(message.color, fallbackSeed: message.login)
    text.append(NSAttributedString(string: message.displayName, attributes: [.font: bold, .foregroundColor: nameColor, .paragraphStyle: paragraph]))
    if message.isDeleted {
      text.append(NSAttributedString(string: ": <message deleted>", attributes: [.font: font, .foregroundColor: UIColor.tertiaryLabel, .paragraphStyle: paragraph]))
      return RenderedMessage(text: text, slots: slots, highlighted: false)
    }
    text.append(NSAttributedString(string: message.kind == .action ? " " : ": ", attributes: plain))
    var body = plain
    if message.kind == .action { body[.foregroundColor] = nameColor }
    for fragment in message.fragments(thirdParty: thirdParty) {
      switch fragment {
      case .text(let t): text.append(NSAttributedString(string: t, attributes: body))
      case .emote(_, let url): slot(url, height: (fontSize * 1.75).rounded(), font: font, into: text, slots: &slots)
      }
    }
    let highlighted = message.systemText != nil || (me.map { message.mentions($0) } ?? false)
    return RenderedMessage(text: text, slots: slots, highlighted: highlighted)
  }
}

/// Coalesces "an image finished loading" into one refresh per quarter second.
enum ChatImageEvents {
  static let notification = Notification.Name("KestrelChatImageArrived")
  private static var scheduled = false

  static func imageArrived() {
    guard !scheduled else { return }
    scheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      scheduled = false
      NotificationCenter.default.post(name: notification, object: nil)
    }
  }
}

/// Draws a message with TextKit and puts (animated) image views exactly over its image slots.
final class ChatMessageView: UIView {
  private let storage = NSTextStorage()
  private let manager = NSLayoutManager()
  private let container = NSTextContainer(size: .zero)
  private var imageViews: [LoadingImageView] = []
  private var slots: [RenderedMessage.Slot] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    container.lineFragmentPadding = 0
    isOpaque = false
    backgroundColor = .clear
    contentMode = .redraw
  }

  required init?(coder: NSCoder) { fatalError() }

  func show(_ rendered: RenderedMessage) {
    storage.setAttributedString(rendered.text)
    slots = rendered.slots
    while imageViews.count < slots.count {
      let view = LoadingImageView()
      view.contentMode = .scaleAspectFit
      addSubview(view)
      imageViews.append(view)
    }
    for (index, view) in imageViews.enumerated() {
      view.isHidden = index >= slots.count
      if index < slots.count { view.load(slots[index].url, maxPixels: 112, fallback: nil) }
    }
    setNeedsLayout()
    setNeedsDisplay()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    container.size = CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
    manager.ensureLayout(for: container)
    for (index, slot) in slots.enumerated() where index < imageViews.count {
      let glyph = manager.glyphIndexForCharacter(at: slot.range.location)
      guard glyph < manager.numberOfGlyphs else { continue }
      let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let location = manager.location(forGlyphAt: glyph)
      let attachment = storage.attribute(.attachment, at: slot.range.location, effectiveRange: nil) as? NSTextAttachment
      let bounds = attachment?.bounds ?? CGRect(origin: .zero, size: slot.size)
      let baseline = line.minY + location.y
      imageViews[index].frame = CGRect(
        x: line.minX + location.x, y: baseline - (bounds.origin.y + bounds.height), width: bounds.width, height: bounds.height)
    }
  }

  override func draw(_ rect: CGRect) {
    let range = manager.glyphRange(for: container)
    manager.drawBackground(forGlyphRange: range, at: .zero)
    manager.drawGlyphs(forGlyphRange: range, at: .zero)
  }

  private static let measuring: (NSTextStorage, NSLayoutManager, NSTextContainer) = {
    let storage = NSTextStorage()
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: .zero)
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    return (storage, manager, container)
  }()

  static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
    let (storage, manager, container) = measuring
    storage.setAttributedString(text)
    container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
    manager.ensureLayout(for: container)
    return ceil(manager.usedRect(for: container).height)
  }
}

final class ChatCell: UITableViewCell {
  let messageView = ChatMessageView()
  static let insets = UIEdgeInsets(top: 3, left: 12, bottom: 3, right: 12)

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    selectionStyle = .none
    contentView.addSubview(messageView)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    messageView.frame = contentView.bounds.inset(by: Self.insets)
  }
}

final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
  private let chat: ChatController
  private let tableView = UITableView(frame: .zero, style: .plain)
  private let resumeButton = UIButton(type: .system)
  private var displayed: [ChatMessage] = []
  private var rendered: [String: RenderedMessage] = [:]
  private var heights: [String: CGFloat] = [:]
  private var lastWidth: CGFloat = 0
  private var following = true
  private var imageObserver: NSObjectProtocol?
  var onMention: ((String) -> Void)?

  init(chat: ChatController) {
    self.chat = chat
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    tableView.backgroundColor = .clear
    tableView.separatorStyle = .none
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(ChatCell.self, forCellReuseIdentifier: "chat")
    tableView.keyboardDismissMode = .interactive
    tableView.showsVerticalScrollIndicator = false
    tableView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(tableView)

    var configuration = UIButton.Configuration.filled()
    configuration.title = "More messages"
    configuration.image = UIImage(systemName: "arrow.down")
    configuration.imagePadding = 6
    configuration.cornerStyle = .capsule
    configuration.baseBackgroundColor = ChatRenderer.accent
    configuration.baseForegroundColor = .white
    configuration.buttonSize = .small
    resumeButton.configuration = configuration
    resumeButton.translatesAutoresizingMaskIntoConstraints = false
    resumeButton.isHidden = true
    resumeButton.addAction(UIAction { [weak self] _ in self?.resume() }, for: .touchUpInside)
    view.addSubview(resumeButton)

    NSLayoutConstraint.activate([
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      resumeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      resumeButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
    ])

    chat.onUpdate = { [weak self] full in self?.chatUpdated(fullReload: full) }
    imageObserver = NotificationCenter.default.addObserver(
      forName: ChatImageEvents.notification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.chatUpdated(fullReload: true)
    }
    chatUpdated(fullReload: true)
  }

  deinit {
    if let imageObserver { NotificationCenter.default.removeObserver(imageObserver) }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if abs(tableView.bounds.width - lastWidth) > 0.5 {
      lastWidth = tableView.bounds.width
      heights = [:]
      tableView.reloadData()
      if following { scrollToBottom() }
    }
  }

  private func key(_ message: ChatMessage) -> String { "\(message.id)-\(message.isDeleted)" }

  private func render(_ message: ChatMessage) -> RenderedMessage {
    let k = key(message)
    if let cached = rendered[k] { return cached }
    let result = ChatRenderer.render(
      message, badges: chat.badges, thirdParty: chat.thirdParty, fontSize: AppSettings.shared.chatFontSize, me: chat.ownLogin)
    rendered[k] = result
    return result
  }

  private func chatUpdated(fullReload: Bool) {
    if fullReload {
      rendered = [:]
      heights = [:]
    }
    guard following else {
      resumeButton.isHidden = false
      if fullReload { tableView.reloadData() }
      return
    }
    displayed = chat.messages
    let live = Set(displayed.map(key))
    rendered = rendered.filter { live.contains($0.key) }
    heights = heights.filter { live.contains($0.key) }
    tableView.reloadData()
    scrollToBottom()
  }

  private func scrollToBottom() {
    guard !displayed.isEmpty else { return }
    tableView.layoutIfNeeded()
    tableView.scrollToRow(at: IndexPath(row: displayed.count - 1, section: 0), at: .bottom, animated: false)
  }

  private func resume() {
    following = true
    resumeButton.isHidden = true
    chatUpdated(fullReload: false)
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { displayed.count }

  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    let message = displayed[indexPath.row]
    let k = key(message)
    if let height = heights[k] { return height }
    let width = max(10, tableView.bounds.width - ChatCell.insets.left - ChatCell.insets.right)
    let height = ChatMessageView.height(of: render(message).text, width: width) + ChatCell.insets.top + ChatCell.insets.bottom
    heights[k] = height
    return height
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "chat", for: indexPath) as! ChatCell
    let result = render(displayed[indexPath.row])
    cell.messageView.show(result)
    cell.contentView.backgroundColor = result.highlighted ? ChatRenderer.accent.withAlphaComponent(0.14) : .clear
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    let message = displayed[indexPath.row]
    guard !message.login.isEmpty, message.kind != .notice else { return }
    onMention?(message.login)
  }

  func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint)
    -> UIContextMenuConfiguration?
  {
    let message = displayed[indexPath.row]
    guard message.kind != .notice else { return nil }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      var actions = [
        UIAction(title: "Copy message", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = message.text }
      ]
      if self?.onMention != nil {
        actions.append(UIAction(title: "Reply to @\(message.displayName)", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in
          self?.onMention?(message.login)
        })
      }
      return UIMenu(children: actions)
    }
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    following = false
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate { checkBottom(scrollView) }
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    checkBottom(scrollView)
  }

  private func checkBottom(_ scrollView: UIScrollView) {
    let bottom = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
    if scrollView.contentOffset.y >= bottom - 30 { resume() }
  }
}

struct ChatMessagesView: UIViewControllerRepresentable {
  let chat: ChatController
  var onMention: ((String) -> Void)?

  func makeUIViewController(context: Context) -> ChatViewController {
    let controller = ChatViewController(chat: chat)
    controller.onMention = onMention
    return controller
  }

  func updateUIViewController(_ controller: ChatViewController, context: Context) {
    controller.onMention = onMention
  }
}

/// Messages plus the box to write in (or a prompt to sign in).
struct ChatPanel: View {
  @ObservedObject var chat: ChatController
  @ObservedObject private var account = TwitchAccount.shared
  @State private var draft = ""
  @State private var showLogin = false
  @FocusState private var focused: Bool

  var body: some View {
    VStack(spacing: 0) {
      ZStack(alignment: .top) {
        ChatMessagesView(chat: chat, onMention: account.session == nil ? nil : { login in
          draft = "@\(login) " + draft
          focused = true
        })
        if case .disconnected(let reason) = chat.status {
          pill(reason)
        } else if chat.status == .connecting {
          pill("Connecting to chat…")
        }
      }
      Divider().overlay(Color.white.opacity(0.08))
      inputBar
    }
    .sheet(isPresented: $showLogin) { TwitchLoginView() }
    .onChange(of: account.session?.login) { _ in chat.reconnect() }
  }

  private func pill(_ text: String) -> some View {
    Text(text).font(.caption.weight(.semibold))
      .padding(.horizontal, 10).padding(.vertical, 5)
      .background(.ultraThinMaterial, in: Capsule())
      .padding(.top, 8)
  }

  @ViewBuilder
  private var inputBar: some View {
    if account.session != nil {
      VStack(alignment: .leading, spacing: 4) {
        if let rules = chat.roomRules {
          Text(rules).font(.caption2).foregroundColor(.secondary).padding(.horizontal, 4)
        }
        HStack(spacing: 8) {
          TextField(chat.canSend ? "Send a message" : "Joining chat…", text: $draft)
            .focused($focused)
            .submitLabel(.send)
            .onSubmit(send)
            .disabled(!chat.canSend)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
          Button(action: send) {
            Image(systemName: "paperplane.fill").font(.system(size: 16, weight: .semibold))
              .frame(width: 36, height: 36)
              .background(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.white.opacity(0.08) : Color.accentTeal, in: Circle())
              .foregroundColor(.white)
          }
          .disabled(!chat.canSend || draft.trimmingCharacters(in: .whitespaces).isEmpty)
          .accessibilityLabel("Send")
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
    } else {
      Button {
        showLogin = true
      } label: {
        Label("Sign in with Twitch to chat", systemImage: "bubble.left.and.text.bubble.right")
          .font(.subheadline.weight(.semibold))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 10)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
    }
  }

  private func send() {
    let text = draft
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    chat.send(text)
    draft = ""
  }
}
