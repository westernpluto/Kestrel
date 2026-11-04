// Minimal HTTP/1.1 server bound to 127.0.0.1, used to hand AVPlayer the cleaned playlists.
// Plain POSIX sockets so the same code runs (and is tested) on Linux.

import Dispatch
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

struct LocalRequest: Sendable {
  var method: String
  var path: String
  var query: [String: String]
  var headers: [String: String]
}

struct LocalResponse: Sendable {
  var status: Int
  var contentType: String
  var body: Data

  static func text(_ status: Int, _ body: String, type: String = "text/plain; charset=utf-8") -> LocalResponse {
    LocalResponse(status: status, contentType: type, body: Data(body.utf8))
  }

  static func playlist(_ body: String) -> LocalResponse {
    LocalResponse(status: 200, contentType: "application/vnd.apple.mpegurl", body: Data(body.utf8))
  }
}

final class LocalHTTPServer: @unchecked Sendable {
  typealias Handler = @Sendable (LocalRequest) async -> LocalResponse

  private let handler: Handler
  private let lock = NSLock()
  private var listenSocket: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  private var socketClosed: DispatchSemaphore?
  private let acceptQueue = DispatchQueue(label: "kestrel.http.accept")
  private let ioQueue = DispatchQueue(label: "kestrel.http.io", attributes: .concurrent)
  private(set) var port: UInt16 = 0

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return acceptSource != nil
  }

  enum ServerError: Error { case socket(Int32), bind(Int32), listen(Int32) }

  /// Starts listening on 127.0.0.1. Tries `preferredPort` first (so URLs survive a restart).
  @discardableResult
  func start(preferredPort: UInt16 = 0) throws -> UInt16 {
    stop()
    signal(SIGPIPE, SIG_IGN)
    #if os(Linux)
      let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
      let fd = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    guard fd >= 0 else { throw ServerError.socket(errno) }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    func bindTo(_ port: UInt16) -> Bool {
      var address = sockaddr_in()
      #if !os(Linux)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      #endif
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = in_port_t(port).bigEndian
      address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
      let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      return result == 0
    }

    if !(preferredPort != 0 && bindTo(preferredPort)) && !bindTo(0) {
      let error = errno
      close(fd)
      throw ServerError.bind(error)
    }
    guard listen(fd, 128) == 0 else {
      let error = errno
      close(fd)
      throw ServerError.listen(error)
    }

    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    let actualPort = UInt16(bigEndian: bound.sin_port)
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
    let closed = DispatchSemaphore(value: 0)
    source.setEventHandler { [weak self] in self?.acceptConnections(fd) }
    source.setCancelHandler {
      close(fd)
      closed.signal()
    }
    lock.lock()
    listenSocket = fd
    socketClosed = closed
    acceptSource = source
    port = actualPort
    lock.unlock()
    source.resume()
    return actualPort
  }

  func stop() {
    lock.lock()
    let source = acceptSource
    acceptSource = nil
    listenSocket = -1
    let closed = socketClosed
    lock.unlock()
    guard let source else { return }
    source.cancel()
    // The socket is closed by the cancel handler; wait for it so the port can be reused right away.
    _ = closed?.wait(timeout: .now() + 1)
  }

  private func acceptConnections(_ fd: Int32) {
    while true {
      var address = sockaddr()
      var length = socklen_t(MemoryLayout<sockaddr>.size)
      let client = accept(fd, &address, &length)
      if client < 0 { return }
      // Accepted sockets inherit O_NONBLOCK on Darwin; this server uses blocking I/O per connection.
      _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
      var yes: Int32 = 1
      #if !os(Linux)
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
      #endif
      setsockopt(client, Int32(IPPROTO_TCP), TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
      var timeout = timeval(tv_sec: 15, tv_usec: 0)
      setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      ioQueue.async { [weak self] in self?.serve(client) }
    }
  }

  private func serve(_ client: Int32) {
    var buffer = [UInt8](repeating: 0, count: 8192)
    var received = Data()
    let terminator = Data("\r\n\r\n".utf8)
    while received.count < 64 * 1024 {
      let count = read(client, &buffer, buffer.count)
      if count <= 0 { break }
      received.append(contentsOf: buffer[0..<count])
      if received.range(of: terminator) != nil { break }
    }
    guard let request = Self.parse(received) else {
      Self.write(LocalResponse.text(400, "bad request"), to: client, includeBody: true)
      close(client)
      return
    }
    let handler = self.handler
    Task.detached {
      let response = await handler(request)
      Self.write(response, to: client, includeBody: request.method != "HEAD")
      close(client)
    }
  }

  static func parse(_ data: Data) -> LocalRequest? {
    guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
    let head = text.components(separatedBy: "\r\n\r\n").first ?? text
    var lines = head.components(separatedBy: "\r\n")
    guard !lines.isEmpty else { return nil }
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else { return nil }
    let target = String(requestLine[1])
    var path = target
    var query: [String: String] = [:]
    if let mark = target.firstIndex(of: "?") {
      path = String(target[..<mark])
      for pair in target[target.index(after: mark)...].split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1)
        let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
        query[key] = value
      }
    }
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    return LocalRequest(method: String(requestLine[0]).uppercased(), path: path, query: query, headers: headers)
  }

  private static func reason(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 404: return "Not Found"
    case 410: return "Gone"
    case 502: return "Bad Gateway"
    case 503: return "Service Unavailable"
    case 504: return "Gateway Timeout"
    default: return "Status"
    }
  }

  private static func write(_ response: LocalResponse, to client: Int32, includeBody: Bool) {
    var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
    head += "Content-Type: \(response.contentType)\r\n"
    head += "Content-Length: \(response.body.count)\r\n"
    head += "Cache-Control: no-cache, no-store\r\n"
    head += "Connection: close\r\n\r\n"
    var payload = Data(head.utf8)
    if includeBody { payload.append(response.body) }
    payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard var pointer = raw.baseAddress else { return }
      var remaining = raw.count
      while remaining > 0 {
        #if os(Linux)
          let sent = send(client, pointer, remaining, Int32(MSG_NOSIGNAL))
        #else
          let sent = send(client, pointer, remaining, 0)
        #endif
        if sent <= 0 { return }
        pointer = pointer.advanced(by: sent)
        remaining -= sent
      }
    }
  }
}

/// Something that serves a master playlist and its media playlists to a local player.
protocol PlaylistSource: AnyObject, Sendable {
  var id: String { get }
  func masterPlaylist(only: Int?) async -> String
  func mediaPlaylist(_ index: Int) async -> (status: Int, body: String)
}

extension StreamSession: PlaylistSource {}

/// Routes `/live/<session>/master.m3u8` and `/live/<session>/v/<n>.m3u8` to playlist sources,
/// and `/static/<id>.m3u8` to fixed playlists.
final class StreamProxy: @unchecked Sendable {
  static let shared = StreamProxy()

  private let lock = NSLock()
  private var sessions: [String: PlaylistSource] = [:]
  private var statics: [String: String] = [:]
  /// Where recordings are (served as `/rec/<id>/<file>`).
  private var recordingsRoot: URL?
  private var server: LocalHTTPServer?
  private var lastPort: UInt16 = 0
  /// When the server last answered a ping.
  private var lastAnswered = Date.distantPast

  /// Starts the server if needed and returns its port.
  func ensureRunning() throws -> UInt16 {
    lock.lock()
    if let server, server.isRunning {
      lock.unlock()
      return server.port
    }
    let preferred = lastPort
    lock.unlock()
    let newServer = LocalHTTPServer { [weak self] request in
      await self?.handle(request) ?? .text(503, "gone")
    }
    let port = try newServer.start(preferredPort: preferred)
    lock.lock()
    server = newServer
    lastPort = port
    lock.unlock()
    return port
  }

  var isAlive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return server?.isRunning ?? false
  }

  /// Restarts the server (e.g. after iOS reclaimed the socket while the app was suspended).
  func restart() throws -> UInt16 {
    lock.lock()
    let old = server
    server = nil
    lock.unlock()
    old?.stop()
    return try ensureRunning()
  }

  func register(_ session: PlaylistSource) throws -> URL {
    let port = try ensureRunning()
    lock.lock()
    sessions[session.id] = session
    lock.unlock()
    return URL(string: "http://127.0.0.1:\(port)/live/\(session.id)/master.m3u8")!
  }

  func masterURL(for session: PlaylistSource, quality: Int?) -> URL? {
    lock.lock()
    let port = server?.port ?? lastPort
    lock.unlock()
    let suffix = quality.map { "?q=\($0)" } ?? ""
    return URL(string: "http://127.0.0.1:\(port)/live/\(session.id)/master.m3u8\(suffix)")
  }

  /// One media playlist of a registered source (e.g. a VOD rendition).
  func mediaURL(for session: PlaylistSource, index: Int) -> URL? {
    lock.lock()
    let port = server?.port ?? lastPort
    lock.unlock()
    return URL(string: "http://127.0.0.1:\(port)/live/\(session.id)/v/\(index).m3u8")
  }

  func remove(_ id: String) {
    lock.lock()
    sessions.removeValue(forKey: id)
    statics.removeValue(forKey: id)
    lock.unlock()
  }

  /// Serves `body` at a local URL until `remove(id)`.
  func publish(_ body: String, id: String) throws -> URL {
    let port = try ensureRunning()
    lock.lock()
    statics[id] = body
    lock.unlock()
    return URL(string: "http://127.0.0.1:\(port)/static/\(id).m3u8")!
  }

  /// Serves the recordings in `root` (each in a folder named by its id).
  func serveRecordings(from root: URL) {
    lock.lock()
    recordingsRoot = root
    lock.unlock()
  }

  /// A recording's playlist on the local server.
  func recordingURL(id: String) throws -> URL {
    let port = try ensureRunning()
    return URL(string: "http://127.0.0.1:\(port)/rec/\(id)/index.m3u8")!
  }

  /// One broadcast's recordings played as one video (see RecordingJoin).
  func joinedRecordingURL(ids: [String]) throws -> URL {
    let port = try ensureRunning()
    return URL(string: "http://127.0.0.1:\(port)/join/\(ids.joined(separator: "/"))/index.m3u8")!
  }

  private func joinedRecording(ids: [String]) -> LocalResponse {
    lock.lock()
    let root = recordingsRoot
    lock.unlock()
    guard let root, !ids.isEmpty, ids.allSatisfy(Self.isPlainName) else { return .text(404, "not found") }
    let pieces = ids.compactMap { id -> (id: String, text: String)? in
      let url = root.appendingPathComponent(id).appendingPathComponent("index.m3u8")
      return (try? String(contentsOf: url, encoding: .utf8)).map { (id, $0) }
    }
    guard !pieces.isEmpty else { return .text(404, "not found") }
    return LocalResponse(status: 200, contentType: "application/vnd.apple.mpegurl", body: Data(RecordingJoin.playlist(pieces).utf8))
  }

  private func recordingFile(id: String, file: String) -> LocalResponse {
    lock.lock()
    let root = recordingsRoot
    lock.unlock()
    guard let root, Self.isPlainName(id), Self.isPlainName(file),
      let data = try? Data(contentsOf: root.appendingPathComponent(id).appendingPathComponent(file))
    else { return .text(404, "not found") }
    let type: String
    if file.hasSuffix(".m3u8") {
      type = "application/vnd.apple.mpegurl"
    } else if file.hasSuffix(".ts") {
      type = "video/mp2t"
    } else {
      type = "video/mp4"
    }
    return LocalResponse(status: 200, contentType: type, body: data)
  }

  /// A file or folder name with nothing that could reach outside the recordings.
  static func isPlainName(_ name: String) -> Bool {
    !name.isEmpty && !name.hasPrefix(".")
      && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
  }

  private func staticBody(_ id: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return statics[id]
  }

  private func session(_ id: String) -> PlaylistSource? {
    lock.lock()
    defer { lock.unlock() }
    return sessions[id]
  }

  func handle(_ request: LocalRequest) async -> LocalResponse {
    let parts = request.path.split(separator: "/").map(String.init)
    if parts == ["ping"] { return .text(200, "pong") }
    if parts.count == 3, parts[0] == "rec" { return recordingFile(id: parts[1], file: parts[2]) }
    if parts.count >= 3, parts[0] == "join", parts.last == "index.m3u8" {
      return joinedRecording(ids: Array(parts[1..<(parts.count - 1)]))
    }
    if parts.count == 2, parts[0] == "static", parts[1].hasSuffix(".m3u8") {
      return staticBody(String(parts[1].dropLast(5))).map { .playlist($0) } ?? .text(404, "not found")
    }
    guard parts.count >= 3, parts[0] == "live", let session = session(parts[1]) else {
      return .text(404, "not found")
    }
    if parts.count == 3, parts[2] == "master.m3u8" {
      let quality = request.query["q"].flatMap(Int.init)
      return .playlist(await session.masterPlaylist(only: quality))
    }
    if parts.count == 4, parts[2] == "v", parts[3].hasSuffix(".m3u8"), let index = Int(parts[3].dropLast(5)) {
      let result = await session.mediaPlaylist(index)
      if result.status == 200 { return .playlist(result.body) }
      return .text(result.status, "upstream \(result.status)")
    }
    return .text(404, "not found")
  }
}

extension StreamProxy {
  /// Pings the server and restarts it if iOS reclaimed the socket while the app was suspended.
  /// A restart cuts off every stream playing through it, so a slow answer isn't taken for a dead
  /// server: several streams starting at once (multi-view coming back from the background) kept it
  /// busy past the first wait, and the restart stalled the stream still playing. It's asked again,
  /// longer, first; and not at all if it answered a moment ago.
  func ensureResponsive() async {
    guard let port = try? ensureRunning() else {
      _ = try? restart()
      return
    }
    if Date().timeIntervalSince(answeredAt) < 5 { return }
    for timeout in [1.5, 3.0] {
      if let url = URL(string: "http://127.0.0.1:\(port)/ping"),
        let result = try? await URLSessionHTTPClient(timeout: timeout).data(for: URLRequest(url: url)),
        result.1.statusCode == 200
      {
        noteAnswered()
        return
      }
    }
    _ = try? restart()
  }

  private var answeredAt: Date {
    lock.lock()
    defer { lock.unlock() }
    return lastAnswered
  }

  private func noteAnswered() {
    lock.lock()
    lastAnswered = Date()
    lock.unlock()
  }
}
