// Spoken translation ("voice-over"): each translated sentence from the live captions is read out
// in your language with the iPhone's own voices, while the stream is turned down underneath (like
// a dubbed interview). It lags the streamer by a few seconds; when they talk faster than it can
// keep up, it skips ahead to the newest sentence instead of falling further behind.

import AVFoundation
import Foundation

@MainActor
final class TranslationVoice: NSObject {
  /// Called with true while speaking (the stream is turned down) and false after.
  var onSpeaking: ((Bool) -> Void)?

  private let synthesizer = AVSpeechSynthesizer()
  private var voice: AVSpeechSynthesisVoice?
  private var language = ""
  private var waiting: [String] = []
  private var speaking = false

  override init() {
    super.init()
    synthesizer.delegate = self
    synthesizer.usesApplicationAudioSession = true
  }

  /// The best voice installed for `code` (premium or enhanced ones if you've downloaded them in
  /// iOS Settings → Accessibility → Spoken Content → Voices).
  func prepare(language code: String) {
    guard code != language else { return }
    language = code
    let voices = AVSpeechSynthesisVoice.speechVoices().filter { LanguageGuess.base($0.language) == code }
    let region = Locale.current.region?.identifier ?? "-"
    func rank(_ voice: AVSpeechSynthesisVoice) -> Int { voice.quality.rawValue * 2 + (voice.language.hasSuffix(region) ? 1 : 0) }
    voice = voices.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: code)
  }

  func say(_ sentence: String) {
    let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    waiting.append(text)
    // Falling behind: drop what hasn't been said yet except the newest.
    if waiting.count > 2 { waiting.removeFirst(waiting.count - 1) }
    if !speaking { next() }
  }

  func stop() {
    waiting = []
    synthesizer.stopSpeaking(at: .immediate)
    if speaking {
      speaking = false
      onSpeaking?(false)
    }
  }

  private func next() {
    guard !waiting.isEmpty else {
      if speaking {
        speaking = false
        onSpeaking?(false)
      }
      return
    }
    let text = waiting.removeFirst()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    // A touch quicker than normal, quicker still with a backlog.
    utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * (waiting.isEmpty ? 1.06 : 1.18))
    utterance.preUtteranceDelay = 0
    utterance.postUtteranceDelay = 0.05
    if !speaking {
      speaking = true
      onSpeaking?(true)
    }
    synthesizer.speak(utterance)
  }

  fileprivate func finished() {
    next()
  }
}

extension TranslationVoice: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor [weak self] in self?.finished() }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor [weak self] in self?.finished() }
  }
}
