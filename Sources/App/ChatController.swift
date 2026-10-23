import Foundation
import SwiftUI
import UIKit

/// Read-only (anonymous) Twitch chat over WebSocket.
@MainActor
final class ChatController: ObservableObject {
  enum Status: Equatable { case connecting, connected, disconnected(String) }

  @Published private(set) var status: Status = .connecting
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
  private let maxMessages = 300

  nonisolated init(channel: Channel) {
    self.channel = channel
  }

  func start() {
    guard !running else { return }
    running = true
    let channel = self.channel
    Task {
      let http = URLSessionHTTPClient(timeout: 10)
      async let history = ThirdPartyEmotes.recentMessages(login: channel.login, http: http)
      async let badgeMap = TwitchAPI.shared.badges(channelID: channel.id)
      let emotes = AppSettings.shared.thirdPartyEmotes ? await ThirdPartyEmotes.load(channelID: channel.id, http: http) : [:]
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

  private func connect() {
    guard running else { return }
    status = .connecting
    let task = URLSession.shared.webSocketTask(with: URL(string: "wss://irc-ws.chat.twitch.tv:443")!)
    socket = task
    task.resume()
    let nick = "justinfan\(Int.random(in: 10000...99999))"
    for line in ["CAP REQ :twitch.tv/tags twitch.tv/commands", "PASS SCHMOOPIIE", "NICK \(nick)", "JOIN #\(channel.login.lowercased())"] {
      task.send(.string(line)) { _ in }
    }
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
      case "ROOMSTATE", "366":
        status = .connected
      case "CLEARMSG":
        if let id = irc.tags["target-msg-id"] { markDeleted { $0.id == id } }
      case "CLEARCHAT":
        if irc.params.count > 1, let login = irc.trailing?.lowercased() {
          markDeleted { $0.login.lowercased() == login }
        }
      case "RECONNECT":
        socket?.cancel(with: .goingAway, reason: nil)
      default:
        if let message = ChatMessage(irc: irc) { enqueue(message) }
      }
    }
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

enum ChatRenderer {
  static func color(_ hex: String?, fallbackSeed: String) -> UIColor {
    var value: UInt64 = 0
    if let hex, hex.hasPrefix("#"), Scanner(string: String(hex.dropFirst())).scanHexInt64(&value) {
      var r = CGFloat((value >> 16) & 0xFF) / 255, g = CGFloat((value >> 8) & 0xFF) / 255, b = CGFloat(value & 0xFF) / 255
      let luminance = 0.299 * r + 0.587 * g + 0.114 * b
      if luminance < 0.4 {  // too dark on a dark background: lighten
        let boost = 0.4 - luminance
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

  private static func attachment(_ url: URL, height: CGFloat, font: UIFont, placeholderText: String?) -> NSAttributedString {
    guard let image = ImageCache.shared.cached(url) else {
      ImageCache.shared.load(url) { _ in ChatImageEvents.imageArrived() }
      if let placeholderText { return NSAttributedString(string: placeholderText, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]) }
      let spacer = NSTextAttachment()
      spacer.bounds = CGRect(x: 0, y: 0, width: height, height: height)
      return NSAttributedString(attachment: spacer)
    }
    let attachment = NSTextAttachment()
    attachment.image = image
    let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
    attachment.bounds = CGRect(x: 0, y: (font.capHeight - height) / 2, width: height * ratio, height: height)
    return NSAttributedString(attachment: attachment)
  }

  static func render(_ message: ChatMessage, badges: [String: Badge], thirdParty: [String: URL], fontSize: CGFloat, timestamps: Bool)
    -> NSAttributedString
  {
    let font = UIFont.systemFont(ofSize: fontSize)
    let bold = UIFont.systemFont(ofSize: fontSize, weight: .bold)
    let text = NSMutableAttributedString()
    let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]

    if message.kind == .notice {
      return NSAttributedString(string: message.text, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
    }
    if timestamps {
      let formatter = DateFormatter()
      formatter.dateFormat = "HH:mm"
      text.append(NSAttributedString(string: formatter.string(from: message.timestamp) + " ", attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: fontSize - 2, weight: .regular), .foregroundColor: UIColor.tertiaryLabel]))
    }
    if let system = message.systemText {
      text.append(NSAttributedString(string: system, attributes: [.font: bold, .foregroundColor: UIColor(red: 0.16, green: 0.78, blue: 0.72, alpha: 1)]))
      if message.text.isEmpty { return text }
      text.append(NSAttributedString(string: "\n", attributes: plain))
    }
    for badge in message.badges {
      guard let info = badges[badge], let url = URL(string: info.imageURL) else { continue }
      text.append(attachment(url, height: fontSize + 3, font: font, placeholderText: nil))
      text.append(NSAttributedString(string: " ", attributes: plain))
    }
    let nameColor = color(message.color, fallbackSeed: message.login)
    text.append(NSAttributedString(string: message.displayName, attributes: [.font: bold, .foregroundColor: nameColor]))
    if message.isDeleted {
      text.append(NSAttributedString(string: ": <message deleted>", attributes: [.font: font, .foregroundColor: UIColor.tertiaryLabel]))
      return text
    }
    text.append(NSAttributedString(string: message.kind == .action ? " " : ": ", attributes: plain))
    let bodyAttributes: [NSAttributedString.Key: Any] = message.kind == .action ? [.font: font, .foregroundColor: nameColor] : plain
    for fragment in message.fragments(thirdParty: thirdParty) {
      switch fragment {
      case .text(let t): text.append(NSAttributedString(string: t, attributes: bodyAttributes))
      case .emote(let name, let url): text.append(attachment(url, height: fontSize * 1.9, font: font, placeholderText: name))
      }
    }
    return text
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

final class ChatCell: UITableViewCell {
  let label = UILabel()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    selectionStyle = .none
    label.numberOfLines = 0
    label.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
      label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
      label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
      label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }
}

final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
  private let chat: ChatController
  private let tableView = UITableView(frame: .zero, style: .plain)
  private let resumeButton = UIButton(type: .system)
  private var displayed: [ChatMessage] = []
  private var rendered = NSCache<NSString, NSAttributedString>()
  private var following = true
  private var imageObserver: NSObjectProtocol?

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
    tableView.estimatedRowHeight = 28
    tableView.rowHeight = UITableView.automaticDimension
    tableView.keyboardDismissMode = .onDrag
    tableView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(tableView)

    var configuration = UIButton.Configuration.filled()
    configuration.title = "More messages below"
    configuration.image = UIImage(systemName: "arrow.down")
    configuration.imagePadding = 6
    configuration.cornerStyle = .capsule
    configuration.baseBackgroundColor = UIColor(red: 0.16, green: 0.78, blue: 0.72, alpha: 1)
    configuration.baseForegroundColor = .black
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
      resumeButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
    ])

    chat.onUpdate = { [weak self] full in self?.chatUpdated(fullReload: full) }
    imageObserver = NotificationCenter.default.addObserver(
      forName: ChatImageEvents.notification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.rendered.removeAllObjects()
      self?.reloadVisible()
    }
    chatUpdated(fullReload: true)
  }

  deinit {
    if let imageObserver { NotificationCenter.default.removeObserver(imageObserver) }
  }

  private func chatUpdated(fullReload: Bool) {
    if fullReload { rendered.removeAllObjects() }
    guard following else {
      resumeButton.isHidden = false
      if fullReload { reloadVisible() }
      return
    }
    displayed = chat.messages
    tableView.reloadData()
    scrollToBottom(animated: false)
  }

  private func reloadVisible() {
    guard let visible = tableView.indexPathsForVisibleRows, !visible.isEmpty else { return }
    UIView.performWithoutAnimation { tableView.reloadRows(at: visible, with: .none) }
    if following { scrollToBottom(animated: false) }
  }

  private func scrollToBottom(animated: Bool) {
    guard !displayed.isEmpty else { return }
    tableView.layoutIfNeeded()
    tableView.scrollToRow(at: IndexPath(row: displayed.count - 1, section: 0), at: .bottom, animated: animated)
  }

  private func resume() {
    following = true
    resumeButton.isHidden = true
    displayed = chat.messages
    tableView.reloadData()
    scrollToBottom(animated: true)
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { displayed.count }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "chat", for: indexPath) as! ChatCell
    let message = displayed[indexPath.row]
    let key = "\(message.id)-\(message.isDeleted)" as NSString
    if let cached = rendered.object(forKey: key) {
      cell.label.attributedText = cached
    } else {
      let settings = AppSettings.shared
      let text = ChatRenderer.render(
        message, badges: chat.badges, thirdParty: chat.thirdParty, fontSize: settings.chatFontSize,
        timestamps: settings.chatTimestamps)
      rendered.setObject(text, forKey: key)
      cell.label.attributedText = text
    }
    return cell
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

struct ChatView: UIViewControllerRepresentable {
  let chat: ChatController
  func makeUIViewController(context: Context) -> ChatViewController { ChatViewController(chat: chat) }
  func updateUIViewController(_ controller: ChatViewController, context: Context) {}
}
