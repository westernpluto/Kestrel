// On-device translation for chat (and live captions), with Apple's Translation framework
// (iOS 18 and later; nothing leaves the iPhone). Chat messages are sorted by language with
// Apple's language identification; each language being translated gets a translation session
// from a hidden view in the player (that's how the framework hands them out, and how it asks to
// download a language the first time).
//
// Built only with an SDK that has the framework (the macOS build); elsewhere `isAvailable` is
// false and nothing here does anything.

import Foundation
import NaturalLanguage
import SwiftUI

#if compiler(>=6.0)
  #if canImport(Translation) && !KESTREL_NO_TRANSLATION
    import Translation
    private let translationBuilt = true
  #else
    private let translationBuilt = false
  #endif
#else
  private let translationBuilt = false
#endif

enum LanguageGuess {
  /// The language of a piece of chat, when it's clear enough to say (short messages, emote
  /// names and "lol" aren't).
  static func code(of text: String, minimumConfidence: Double = 0.7) -> String? {
    let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
    guard letters >= 8 else { return nil }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
      language != .undetermined, confidence >= minimumConfidence
    else { return nil }
    return base(language.rawValue)
  }

  /// "es-419" → "es"; Chinese keeps its script ("zh-Hans").
  static func base(_ identifier: String) -> String {
    if identifier.hasPrefix("zh") { return identifier.contains("Hant") ? "zh-Hant" : "zh-Hans" }
    return String(identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(identifier))
  }

  /// The language Twitch's language tags name (they're written in the language itself).
  static func code(fromTags tags: [String]) -> String? {
    let names: [String: String] = [
      "english": "en", "español": "es", "spanish": "es", "français": "fr", "french": "fr", "deutsch": "de",
      "german": "de", "português": "pt", "portuguese": "pt", "italiano": "it", "italian": "it",
      "русский": "ru", "russian": "ru", "日本語": "ja", "japanese": "ja", "한국어": "ko", "korean": "ko",
      "中文": "zh-Hans", "chinese": "zh-Hans", "polski": "pl", "polish": "pl", "türkçe": "tr", "turkish": "tr",
      "العربية": "ar", "arabic": "ar", "nederlands": "nl", "dutch": "nl", "svenska": "sv", "swedish": "sv",
      "українська": "uk", "ukrainian": "uk", "ไทย": "th", "thai": "th", "tiếng việt": "vi", "vietnamese": "vi",
      "bahasa indonesia": "id", "indonesian": "id", "हिन्दी": "hi", "hindi": "hi", "čeština": "cs", "czech": "cs",
      "dansk": "da", "danish": "da", "suomi": "fi", "finnish": "fi", "norsk": "nb", "norwegian": "nb",
      "magyar": "hu", "hungarian": "hu", "română": "ro", "romanian": "ro", "ελληνικά": "el", "greek": "el",
    ]
    for tag in tags { if let code = names[tag.lowercased()] { return code } }
    return nil
  }

  /// The iPhone's language ("en").
  static var mine: String { base(Locale.preferredLanguages.first ?? "en") }

  static func name(_ code: String) -> String {
    Locale.current.localizedString(forIdentifier: code) ?? Locale.current.localizedString(forLanguageCode: code) ?? code
  }
}

@MainActor
final class ChatTranslator: ObservableObject {
  /// This iPhone and this build can translate.
  static var isAvailable: Bool {
    guard translationBuilt else { return false }
    if #available(iOS 18.0, *) { return true }
    return false
  }

  /// Translate chat messages in other languages as they arrive.
  @Published private(set) var autoTranslate = false
  /// Languages being translated from (each has a hidden translation session).
  @Published private(set) var sources: [String] = []
  let target = LanguageGuess.mine
  /// Translations ready, by message ID.
  private(set) var results: [String: String] = [:]
  /// A message's translation arrived (its row is redrawn).
  var onTranslated: ((String) -> Void)?

  private var queues: [String: [(id: String, text: String)]] = [:]
  private var waiters: [String: CheckedContinuation<String?, Never>] = [:]
  private var requested: Set<String> = []
  /// Languages the viewer has agreed to (a download may be asked for once).
  private var permitted: Set<String> = []
  private var failed: Set<String> = []
  private var installed: [String: Bool] = [:]
  /// How often each language turned up in chat lately (the chat's main language gets permitted
  /// when translation is switched on).
  private var seen: [String: Int] = [:]

  /// The chat's main other language, if there's a clear one.
  var mainChatLanguage: String? {
    seen.filter { $0.key != target && $0.value >= 3 }.max { $0.value < $1.value }?.key
  }

  func setAutoTranslate(_ on: Bool, recent: [(id: String, text: String)]) {
    autoTranslate = on
    guard on else { return }
    for item in recent { noteLanguage(of: item.text) }
    if let main = mainChatLanguage { permitted.insert(main) }
    // The last few messages too, so turning it on shows something straight away.
    for item in recent.suffix(15) { consider(id: item.id, text: item.text) }
  }

  /// A new chat message: translated if auto-translate is on and it's in another language that
  /// can be translated without asking.
  func consider(id: String, text: String) {
    guard Self.isAvailable, !requested.contains(id) else { return }
    guard let code = noteLanguage(of: text) else { return }
    guard autoTranslate, code != target, !failed.contains(code) else { return }
    if !permitted.contains(code), mainChatLanguage == code { permitted.insert(code) }
    Task {
      var allowed = permitted.contains(code)
      if !allowed { allowed = await isInstalled(code) }
      guard allowed else { return }
      enqueue(id: id, text: text, from: code)
    }
  }

  /// Translate one message (asked for; may download its language).
  func translateNow(id: String, text: String) {
    guard Self.isAvailable, !requested.contains(id) || results[id] == nil else { return }
    let code = LanguageGuess.code(of: text, minimumConfidence: 0.3) ?? mainChatLanguage
    guard let code, code != target else { return }
    permitted.insert(code)
    failed.remove(code)
    requested.remove(id)
    enqueue(id: id, text: text, from: code)
  }

  /// Translates a piece of text (live captions). Nil if it can't be.
  func translate(_ text: String, from code: String) async -> String? {
    guard Self.isAvailable, code != target, !failed.contains(code) else { return nil }
    permitted.insert(code)
    let id = "text-" + UUID().uuidString
    // Never wait forever (the language may still be downloading, or the session went away).
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      self?.giveUp(on: id)
    }
    return await withCheckedContinuation { continuation in
      wait(for: id, continuation, text: text, from: code)
    }
  }

  private func wait(for id: String, _ continuation: CheckedContinuation<String?, Never>, text: String, from code: String) {
    waiters[id] = continuation
    enqueue(id: id, text: text, from: code)
  }

  private func giveUp(on id: String) {
    waiters.removeValue(forKey: id)?.resume(returning: nil)
    for code in queues.keys { queues[code]?.removeAll { $0.id == id } }
  }

  @discardableResult
  private func noteLanguage(of text: String) -> String? {
    guard let code = LanguageGuess.code(of: text) else { return nil }
    seen[code, default: 0] += 1
    return code
  }

  private func enqueue(id: String, text: String, from code: String) {
    requested.insert(id)
    queues[code, default: []].append((id, text))
    if !sources.contains(code) {
      sources.append(code)
      // At most three languages at once: the oldest idle one makes room.
      if sources.count > 3, let idle = sources.first(where: { queues[$0]?.isEmpty ?? true }) {
        sources.removeAll { $0 == idle }
      }
    }
  }

  private func deliver(_ id: String, _ text: String?) {
    if let waiter = waiters.removeValue(forKey: id) {
      waiter.resume(returning: text)
      return
    }
    guard let text, !text.isEmpty else { return }
    results[id] = text
    onTranslated?(id)
  }

  private func drain(_ code: String) {
    for item in queues[code] ?? [] { deliver(item.id, nil) }
    queues[code] = []
  }

  private func isInstalled(_ code: String) async -> Bool {
    if let known = installed[code] { return known }
    let result = await Self.checkInstalled(code, target: target)
    installed[code] = result
    return result
  }

  private static func checkInstalled(_ code: String, target: String) async -> Bool {
    #if compiler(>=6.0)
      #if canImport(Translation) && !KESTREL_NO_TRANSLATION
        if #available(iOS 18.0, *) {
          let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: code), to: Locale.Language(identifier: target))
          return status == .installed
        }
      #endif
    #endif
    return false
  }

  #if compiler(>=6.0)
    #if canImport(Translation) && !KESTREL_NO_TRANSLATION
      /// Runs for as long as the hidden view for `code` exists, translating what's queued.
      @available(iOS 18.0, *)
      func serve(_ code: String, session: TranslationSession) async {
        do {
          // Asks to download the language the first time (only for languages the viewer chose).
          try await session.prepareTranslation()
          installed[code] = true
        } catch {
          if !Task.isCancelled {
            failed.insert(code)
            ActivityLog.shared.add("Can't translate \(LanguageGuess.name(code)): \(error.localizedDescription)")
            drain(code)
            sources.removeAll { $0 == code }
          }
          return
        }
        while !Task.isCancelled {
          let queue = queues[code] ?? []
          guard !queue.isEmpty else {
            try? await Task.sleep(nanoseconds: 200_000_000)
            continue
          }
          let batch = Array(queue.prefix(12))
          queues[code] = Array(queue.dropFirst(batch.count))
          let requests = batch.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
          do {
            let responses = try await session.translations(from: requests)
            var answered = Set<String>()
            for response in responses {
              guard let id = response.clientIdentifier else { continue }
              answered.insert(id)
              let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
              let source = batch.first { $0.id == id }?.text ?? ""
              deliver(id, text.caseInsensitiveCompare(source) == .orderedSame ? nil : text)
            }
            for item in batch where !answered.contains(item.id) { deliver(item.id, nil) }
          } catch {
            for item in batch { deliver(item.id, nil) }
            if Task.isCancelled { break }
          }
        }
        drain(code)
      }
    #endif
  #endif
}

/// The hidden views that hold the translation sessions (one per language). Lives in the player.
struct TranslationHosts: View {
  @ObservedObject var translator: ChatTranslator

  var body: some View {
    ZStack {
      #if compiler(>=6.0)
        #if canImport(Translation) && !KESTREL_NO_TRANSLATION
          if #available(iOS 18.0, *) {
            ForEach(translator.sources, id: \.self) { code in
              TranslationHost(code: code, translator: translator)
            }
          }
        #endif
      #endif
    }
    .frame(width: 1, height: 1)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

#if compiler(>=6.0)
  #if canImport(Translation) && !KESTREL_NO_TRANSLATION
    @available(iOS 18.0, *)
    private struct TranslationHost: View {
      let code: String
      let translator: ChatTranslator

      var body: some View {
        Color.clear
          .frame(width: 1, height: 1)
          .translationTask(
            TranslationSession.Configuration(
              source: Locale.Language(identifier: code), target: Locale.Language(identifier: translator.target))
          ) { session in
            await translator.serve(code, session: session)
          }
      }
    }
  #endif
#endif
