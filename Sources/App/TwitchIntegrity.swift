// Following and unfollowing on Twitch: Twitch only accepts those from its own website, which
// proves itself with an "integrity" token (the site's bot protection gets it). Like Xtra on
// Android, Kestrel opens twitch.tv invisibly, lets the site get a token, and uses it for the
// follow request. Tokens last several hours, so this only happens once in a while.

import Foundation
import UIKit
import WebKit

@MainActor
final class TwitchIntegrity: NSObject {
  static let shared = TwitchIntegrity()

  private struct Grant {
    var headers: [String: String]
    var userID: String
    var expires: Date
  }

  enum Failure: Error, LocalizedError {
    case notSignedIn
    case timedOut
    case refused(String)
    var errorDescription: String? {
      switch self {
      case .notSignedIn: return "Not signed in"
      case .timedOut: return "twitch.tv didn't hand out a token in time"
      case .refused(let reason): return "twitch.tv refused (\(reason))"
      }
    }
  }

  private var grant: Grant?
  private var webView: WKWebView?
  private var waiting: [CheckedContinuation<[String: String], Error>] = []
  private var deadline: Task<Void, Never>?
  private var askedManually = 0
  private var lastError: String?

  /// Headers that make a GQL request look like it came from twitch.tv itself.
  func headers(refresh: Bool = false) async throws -> [String: String] {
    guard let session = TwitchAuth.shared.session else { throw Failure.notSignedIn }
    if !refresh, let grant, grant.userID == session.userID, grant.expires > Date() { return grant.headers }
    if refresh { grant = nil }
    return try await withCheckedThrowingContinuation { continuation in
      waiting.append(continuation)
      if webView == nil { start() }
    }
  }

  func invalidate() {
    grant = nil
  }

  // MARK: The invisible twitch.tv page

  private static let hook = """
    (function () {
      if (window.__kestrelHooked) return;
      window.__kestrelHooked = true;
      var wanted = ['client-integrity', 'x-device-id', 'client-id', 'client-session-id', 'client-version', 'authorization'];
      function post(message) {
        try { window.webkit.messageHandlers.kestrelIntegrity.postMessage(message); } catch (e) {}
      }
      function collect(headers, out) {
        if (!headers) return out;
        try {
          if (typeof Headers !== 'undefined' && headers instanceof Headers) {
            headers.forEach(function (value, key) { if (wanted.indexOf(key.toLowerCase()) >= 0) out[key.toLowerCase()] = String(value); });
          } else if (Array.isArray(headers)) {
            headers.forEach(function (pair) { var key = String(pair[0]).toLowerCase(); if (wanted.indexOf(key) >= 0) out[key] = String(pair[1]); });
          } else {
            Object.keys(headers).forEach(function (key) { if (wanted.indexOf(key.toLowerCase()) >= 0) out[key.toLowerCase()] = String(headers[key]); });
          }
        } catch (e) {}
        return out;
      }
      var originalFetch = window.fetch;
      window.fetch = function (input, init) {
        try {
          var url = typeof input === 'string' ? input : (input && input.url) || '';
          if (url.indexOf('gql.twitch.tv') >= 0) {
            var headers = {};
            if (typeof Request !== 'undefined' && input instanceof Request) collect(input.headers, headers);
            collect(init && init.headers, headers);
            if (url.indexOf('/integrity') >= 0) {
              return originalFetch.apply(this, arguments).then(function (response) {
                try {
                  response.clone().json().then(function (json) {
                    if (json && json.token) post({ kind: 'token', token: json.token, expiration: json.expiration || 0, headers: headers });
                    else post({ kind: 'error', message: JSON.stringify(json).slice(0, 160) });
                  }).catch(function () {});
                } catch (e) {}
                return response;
              });
            }
            if (headers['client-integrity']) post({ kind: 'headers', headers: headers });
          }
        } catch (e) {}
        return originalFetch.apply(this, arguments);
      };
      var open = XMLHttpRequest.prototype.open;
      var setHeader = XMLHttpRequest.prototype.setRequestHeader;
      var send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__kestrelURL = String(url);
        this.__kestrelHeaders = {};
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.setRequestHeader = function (key, value) {
        try {
          if (this.__kestrelHeaders && wanted.indexOf(String(key).toLowerCase()) >= 0) this.__kestrelHeaders[String(key).toLowerCase()] = String(value);
        } catch (e) {}
        return setHeader.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        try {
          if (this.__kestrelURL && this.__kestrelURL.indexOf('gql.twitch.tv') >= 0 && this.__kestrelHeaders['client-integrity']) {
            post({ kind: 'headers', headers: this.__kestrelHeaders });
          }
        } catch (e) {}
        return send.apply(this, arguments);
      };
    })();
    """

  /// Asks for a token from inside the page, the way the site does (its bot protection adds what
  /// it needs to the request on the way out).
  private static let ask = """
    return fetch('https://gql.twitch.tv/integrity', {
      method: 'POST',
      headers: { 'Client-Id': clientID, 'Authorization': 'OAuth ' + token, 'X-Device-Id': device }
    }).then(function (r) { return r.json(); }).then(function (json) {
      if (json && json.token) {
        window.webkit.messageHandlers.kestrelIntegrity.postMessage({ kind: 'token', token: json.token, expiration: json.expiration || 0, mine: true });
      } else {
        window.webkit.messageHandlers.kestrelIntegrity.postMessage({ kind: 'error', message: JSON.stringify(json).slice(0, 160) });
      }
      return true;
    }).catch(function (e) {
      window.webkit.messageHandlers.kestrelIntegrity.postMessage({ kind: 'error', message: String(e) });
      return false;
    });
    """

  private func start() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    let controller = WKUserContentController()
    controller.addUserScript(WKUserScript(source: Self.hook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    controller.add(WeakMessageHandler(self), name: "kestrelIntegrity")
    configuration.userContentController = controller
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    let view = WKWebView(frame: CGRect(x: -20, y: -20, width: 8, height: 8), configuration: configuration)
    view.customUserAgent = Browser.userAgent
    view.navigationDelegate = self
    view.alpha = 0.01
    view.isUserInteractionEnabled = false
    // Pages that aren't on screen at all get throttled; this one sits invisibly off the edge.
    keyWindow()?.addSubview(view)
    webView = view
    askedManually = 0
    lastError = nil
    view.load(URLRequest(url: URL(string: "https://www.twitch.tv/")!))
    deadline = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 25_000_000_000)
      self?.finish(.failure(self?.lastError.map(Failure.refused) ?? Failure.timedOut))
    }
  }

  private func askManually() {
    guard let webView, let session = TwitchAuth.shared.session, askedManually < 2 else { return }
    askedManually += 1
    webView.callAsyncJavaScript(
      Self.ask,
      arguments: ["clientID": TwitchAPI.webClientID, "token": session.token, "device": TwitchAPI.shared.accountDeviceID],
      in: nil, in: .page, completionHandler: nil)
  }

  fileprivate func received(_ body: Any) {
    guard let message = body as? [String: Any], let kind = message["kind"] as? String,
      let session = TwitchAuth.shared.session
    else { return }
    let captured = (message["headers"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    // Only what belongs to this account (a signed-out page gets tokens for nobody).
    let ours = message["mine"] as? Bool == true || captured["authorization"] == "OAuth \(session.token)"
    switch kind {
    case "token":
      guard ours, let token = message["token"] as? String else { return }
      var headers = [
        "Client-Integrity": token,
        "X-Device-Id": captured["x-device-id"] ?? TwitchAPI.shared.accountDeviceID,
      ]
      if let value = captured["client-session-id"] { headers["Client-Session-Id"] = value }
      if let value = captured["client-version"] { headers["Client-Version"] = value }
      let milliseconds = message["expiration"] as? Double ?? 0
      let expires = milliseconds > 0 ? Date(timeIntervalSince1970: milliseconds / 1000) : Date().addingTimeInterval(8 * 3600)
      finish(.success(Grant(headers: headers, userID: session.userID, expires: min(expires, Date().addingTimeInterval(15 * 3600)).addingTimeInterval(-300))))
    case "headers":
      guard ours, let token = captured["client-integrity"] else { return }
      var headers = ["Client-Integrity": token]
      if let value = captured["x-device-id"] { headers["X-Device-Id"] = value }
      if let value = captured["client-session-id"] { headers["Client-Session-Id"] = value }
      if let value = captured["client-version"] { headers["Client-Version"] = value }
      finish(.success(Grant(headers: headers, userID: session.userID, expires: Date().addingTimeInterval(4 * 3600))))
    case "error":
      lastError = message["message"] as? String
      // Try once more a bit later (the site's protection may still have been loading).
      DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.askManually() }
    default:
      break
    }
  }

  private func finish(_ result: Result<Grant, Error>) {
    guard webView != nil || !waiting.isEmpty else { return }
    deadline?.cancel()
    deadline = nil
    webView?.stopLoading()
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "kestrelIntegrity")
    webView?.removeFromSuperview()
    webView = nil
    let continuations = waiting
    waiting = []
    switch result {
    case .success(let grant):
      self.grant = grant
      ActivityLog.shared.add("Twitch integrity token received (for following)")
      continuations.forEach { $0.resume(returning: grant.headers) }
    case .failure(let error):
      ActivityLog.shared.add("Couldn't get a Twitch integrity token: \(error.localizedDescription)")
      continuations.forEach { $0.resume(throwing: error) }
    }
  }

  private func keyWindow() -> UIWindow? {
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    return windows.first { $0.isKeyWindow } ?? windows.first
  }
}

extension TwitchIntegrity: WKNavigationDelegate {
  nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    // The site usually fetches a token by itself; if it hasn't after a moment, ask for one.
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      self?.askManually()
    }
  }
}

/// The page's messages, without the page keeping Kestrel's object alive.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
  weak var owner: TwitchIntegrity?

  init(_ owner: TwitchIntegrity) {
    self.owner = owner
  }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    let body = message.body
    Task { @MainActor [weak owner] in owner?.received(body) }
  }
}
