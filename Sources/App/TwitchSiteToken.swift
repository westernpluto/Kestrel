// The playback session twitch.tv's own player gets for a channel. A subscriber's session asked for
// by Kestrel (even with the site's integrity proof) can say "subscriber no" while the website
// says the sub is ad-free; this opens the channel's page invisibly, signed in as the website is,
// and keeps the session its player asks for.

import Foundation
import UIKit
import WebKit

@MainActor
final class TwitchSiteToken: NSObject {
  static let shared = TwitchSiteToken()

  private var webView: WKWebView?
  private var waiting: [CheckedContinuation<PlaybackToken?, Never>] = []
  private var login: String?
  private var deadline: Task<Void, Never>?

  /// The channel page's own session, or nil if none came within `wait` seconds.
  func token(login: String, wait: Double) async -> PlaybackToken? {
    let login = login.lowercased()
    return await withCheckedContinuation { continuation in
      if self.login != nil, self.login != login { finish(nil) }
      waiting.append(continuation)
      if webView == nil { start(login, wait: wait) }
    }
  }

  private static let hook = """
    (function () {
      if (window.__kestrelTokenHooked) return;
      window.__kestrelTokenHooked = true;
      function find(json) {
        var list = Array.isArray(json) ? json : [json];
        for (var i = 0; i < list.length; i++) {
          var t = list[i] && list[i].data && list[i].data.streamPlaybackAccessToken;
          if (t && t.value && t.signature) return t;
        }
        return null;
      }
      var originalFetch = window.fetch;
      window.fetch = function (input, init) {
        var url = typeof input === 'string' ? input : (input && input.url) || '';
        var result = originalFetch.apply(this, arguments);
        if (url.indexOf('gql.twitch.tv') >= 0) {
          result.then(function (response) {
            response.clone().json().then(function (json) {
              var t = find(json);
              if (t) window.webkit.messageHandlers.kestrelSiteToken.postMessage({ value: t.value, signature: t.signature });
            }).catch(function () {});
          }).catch(function () {});
        }
        return result;
      };
    })();
    """

  private func start(_ login: String, wait: Double) {
    self.login = login
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    let controller = WKUserContentController()
    controller.addUserScript(WKUserScript(source: Self.hook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    controller.add(SiteTokenHandler(self), name: "kestrelSiteToken")
    configuration.userContentController = controller
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    configuration.allowsInlineMediaPlayback = true
    let view = WKWebView(frame: CGRect(x: -20, y: -20, width: 8, height: 8), configuration: configuration)
    view.customUserAgent = Browser.userAgent
    view.alpha = 0.01
    view.isUserInteractionEnabled = false
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    (windows.first { $0.isKeyWindow } ?? windows.first)?.addSubview(view)
    webView = view
    view.load(URLRequest(url: URL(string: "https://www.twitch.tv/\(login)")!))
    deadline = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
      self?.finish(nil)
    }
  }

  fileprivate func received(_ body: Any) {
    guard let message = body as? [String: Any], let value = message["value"] as? String,
      let signature = message["signature"] as? String
    else { return }
    let token = PlaybackToken(value: value, signature: signature)
    // Only this account's (a signed-out page's session is for nobody).
    guard token.info?.signedIn == true else { return }
    finish(token)
  }

  private func finish(_ token: PlaybackToken?) {
    deadline?.cancel()
    deadline = nil
    webView?.stopLoading()
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "kestrelSiteToken")
    webView?.removeFromSuperview()
    webView = nil
    login = nil
    let continuations = waiting
    waiting = []
    continuations.forEach { $0.resume(returning: token) }
  }
}

private final class SiteTokenHandler: NSObject, WKScriptMessageHandler {
  weak var owner: TwitchSiteToken?
  init(_ owner: TwitchSiteToken) { self.owner = owner }
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    let body = message.body
    Task { @MainActor [weak owner] in owner?.received(body) }
  }
}
