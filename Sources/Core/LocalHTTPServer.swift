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

/// Routes `/live/<session>/master.m3u8` and `/live/<session>/v/<n>.m3u8` to stream sessions,
/// and `/static/<id>.m3u8` to fixed playlists (the low-latency player's master).
final class StreamProxy: @unchecked Sendable {
  static let shared = StreamProxy()

  private let lock = NSLock()
  private var sessions: [String: StreamSession] = [:]
  private var statics: [String: String] = [:]
  private var server: LocalHTTPServer?
  private var lastPort: UInt16 = 0

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

  func register(_ session: StreamSession) throws -> URL {
    let port = try ensureRunning()
    lock.lock()
    sessions[session.id] = session
    lock.unlock()
    return URL(string: "http://127.0.0.1:\(port)/live/\(session.id)/master.m3u8")!
  }

  func masterURL(for session: StreamSession, quality: Int?) -> URL? {
    lock.lock()
    let port = server?.port ?? lastPort
    lock.unlock()
    let suffix = quality.map { "?q=\($0)" } ?? ""
    return URL(string: "http://127.0.0.1:\(port)/live/\(session.id)/master.m3u8\(suffix)")
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

  private func staticBody(_ id: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return statics[id]
  }

  private func session(_ id: String) -> StreamSession? {
    lock.lock()
    defer { lock.unlock() }
    return sessions[id]
  }

  func handle(_ request: LocalRequest) async -> LocalResponse {
    let parts = request.path.split(separator: "/").map(String.init)
    if parts == ["ping"] { return .text(200, "pong") }
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
  func ensureResponsive() async {
    if let port = try? ensureRunning(), let url = URL(string: "http://127.0.0.1:\(port)/ping") {
      if let result = try? await URLSessionHTTPClient(timeout: 1.5).data(for: URLRequest(url: url)),
        result.1.statusCode == 200
      {
        return
      }
    }
    _ = try? restart()
  }
}
