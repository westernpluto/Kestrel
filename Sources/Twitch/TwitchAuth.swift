// Signing in to Twitch: with the account's token, Twitch serves Turbo and subscriber sessions
// without ads, and some channels only offer their best qualities (1440p) to signed-in viewers.

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TwitchAuth: @unchecked Sendable {
  static let shared = TwitchAuth()

  struct Session: Equatable, Sendable, Codable {
    /// The website's `auth-token` cookie (an OAuth token for Twitch's web client).
    var token: String
    var login: String
    var userID: String
    /// The website's `unique_id` cookie; Twitch expects it with the token.
    var deviceID: String?
    /// The client the token belongs to, when it isn't the website's (signing in with a code goes
    /// through Twitch's TV app, see TwitchDeviceLogin): requests with the token carry its ID.
    var clientID: String? = nil
    /// For a new token when this one runs out (signing in with a code).
    var refreshToken: String? = nil
  }

  private let lock = NSLock()
  private var current: Session?

  var session: Session? {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func update(_ session: Session?) {
    lock.lock()
    current = session
    lock.unlock()
  }

  enum ValidationError: Error, LocalizedError {
    case invalid
    case otherClient
    var errorDescription: String? {
      switch self {
      case .invalid: return "Twitch didn't accept this token. Sign in again."
      case .otherClient: return "This token belongs to another app. Use the website's auth-token."
      }
    }
  }

  /// Checks a token with Twitch and returns who it belongs to.
  /// - Parameter clientID: the client the token should belong to (the website's by default).
  static func validate(token: String, http: HTTPClient, clientID: String = TwitchAPI.webClientID) async throws
    -> (login: String, userID: String)
  {
    var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!)
    request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 10
    let (data, response) = try await http.data(for: request)
    guard response.statusCode == 200,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let login = object["login"] as? String, let userID = object["user_id"] as? String
    else { throw ValidationError.invalid }
    if let client = object["client_id"] as? String, client != clientID { throw ValidationError.otherClient }
    return (login, userID)
  }
}
