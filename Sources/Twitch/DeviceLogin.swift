// Signing in with a code, the way Twitch's TV apps do (ported from the Android app's
// TwitchDeviceLogin): Kestrel gets a short code from Twitch, you enter it at twitch.tv/activate in
// any browser where you're signed in (a phone, a computer), and Twitch hands Kestrel a token.
// Nothing of Twitch's website has to run inside Kestrel, which is what a TV needs.

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum TwitchDeviceLogin {
  /// Twitch's own TV app (its tokens go with this Client-ID).
  static let clientID = "ue6666qo983tsx6so1t0vnawi233wa"

  /// Asked for first; if Twitch won't take the list, the smaller one.
  static let scopeSets = [
    "channel_read chat:read chat:edit user_blocks_edit user_blocks_read user_follows_edit user_read",
    "channel_read chat:read user_blocks_edit user_blocks_read user_follows_edit user_read",
  ]

  struct Code: Equatable, Sendable {
    var deviceCode: String
    var userCode: String
    /// Twitch's activation page with the code filled in.
    var verificationURI: String
    var interval: TimeInterval
    var expiresAt: Date
    var scopes: String
  }

  struct Grant: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Int?
  }

  enum Poll: Equatable, Sendable {
    case pending
    case slowDown
    case expired
    case refused(String)
    case done(Grant)
  }

  struct Failure: LocalizedError {
    var errorDescription: String?
  }

  static func form(_ url: String, _ fields: [(String, String)]) -> URLRequest {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue(Browser.userAgent, forHTTPHeaderField: "User-Agent")
    request.httpBody = Data(fields.map { "\(Usher.percentEncode($0.0))=\(Usher.percentEncode($0.1))" }.joined(separator: "&").utf8)
    return request
  }

  private static func json(_ data: Data) -> JSONValue { JSONValue(try? JSONSerialization.jsonObject(with: data)) }

  /// A fresh code to enter at twitch.tv/activate.
  static func start(http: HTTPClient, now: Date = Date()) async throws -> Code {
    var lastError = "no answer"
    for scopes in scopeSets {
      let result: (Data, HTTPURLResponse)
      do {
        result = try await http.data(
          for: form("https://id.twitch.tv/oauth2/device", [("client_id", clientID), ("scopes", scopes)]))
      } catch {
        throw Failure(errorDescription: "Couldn't reach Twitch (\(error.localizedDescription)).")
      }
      if let code = parseCode(result.0, status: result.1.statusCode, scopes: scopes, now: now) { return code }
      let body = json(result.0)
      lastError = body["message"].string ?? "HTTP \(result.1.statusCode)"
    }
    throw Failure(errorDescription: "Twitch didn't give a code (\(lastError)).")
  }

  static func parseCode(_ data: Data, status: Int, scopes: String, now: Date = Date()) -> Code? {
    let body = json(data)
    guard status == 200, let device = body["device_code"].string, let user = body["user_code"].string else { return nil }
    let expiresIn = body["expires_in"].int ?? 1800
    return Code(
      deviceCode: device, userCode: user,
      verificationURI: body["verification_uri"].string ?? "https://www.twitch.tv/activate?device-code=\(user)",
      interval: TimeInterval(min(30, max(2, body["interval"].int ?? 5))),
      expiresAt: now.addingTimeInterval(TimeInterval(expiresIn)), scopes: scopes)
  }

  /// Whether the code has been approved yet.
  static func poll(_ code: Code, http: HTTPClient) async -> Poll {
    let request = form(
      "https://id.twitch.tv/oauth2/token",
      [
        ("client_id", clientID), ("scopes", code.scopes), ("device_code", code.deviceCode),
        ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
      ])
    guard let (data, response) = try? await http.data(for: request) else { return .pending }
    return parsePoll(data, status: response.statusCode)
  }

  static func parsePoll(_ data: Data, status: Int) -> Poll {
    let body = json(data)
    if status == 200, let token = body["access_token"].string {
      return .done(Grant(accessToken: token, refreshToken: body["refresh_token"].string, expiresIn: body["expires_in"].int))
    }
    let text = body["message"].string ?? body["error"].string ?? "HTTP \(status)"
    let lower = text.lowercased()
    if lower.contains("pending") { return .pending }
    if lower.contains("slow") { return .slowDown }
    if lower.contains("invalid device code") || lower.contains("expired") { return .expired }
    if status >= 500 { return .pending }
    return .refused(text)
  }

  /// A new token for one about to run out; nil when Twitch no longer takes the refresh token.
  static func refresh(_ refreshToken: String, clientID: String = TwitchDeviceLogin.clientID, http: HTTPClient) async throws
    -> Grant?
  {
    let (data, response) = try await http.data(
      for: form(
        "https://id.twitch.tv/oauth2/token",
        [("client_id", clientID), ("grant_type", "refresh_token"), ("refresh_token", refreshToken)]))
    let body = json(data)
    if response.statusCode == 200, let token = body["access_token"].string {
      return Grant(accessToken: token, refreshToken: body["refresh_token"].string ?? refreshToken, expiresIn: body["expires_in"].int)
    }
    if response.statusCode >= 500 { throw Failure(errorDescription: "Twitch answered HTTP \(response.statusCode)") }
    return nil
  }
}
