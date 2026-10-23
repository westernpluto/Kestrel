// Live captions of what the streamer says, translated when the stream is in another language.
// Experimental, iOS 26: the stream's audio-only rendition is followed separately (LiveAudioFeed),
// decoded, and fed to Apple's on-device speech recognition (SpeechAnalyzer); finished sentences
// are translated on the iPhone (ChatTranslator) and shown over the video. Nothing is sent
// anywhere. The first time, iOS downloads the speech model for the stream's language.

import AVFoundation
import Foundation

#if compiler(>=6.2)
  #if canImport(Speech) && !KESTREL_NO_CAPTIONS
    import Speech
    private let captionsBuilt = true
  #else
    private let captionsBuilt = false
  #endif
#else
  private let captionsBuilt = false
#endif

@MainActor
final class LiveCaptions {
  /// This iPhone and this build can do live captions.
  static var isAvailable: Bool {
    guard captionsBuilt else { return false }
    if #available(iOS 26.0, *) { return true }
    return false
  }

  struct Setup: Sendable {
    /// The stream's audio-only playlist (Twitch's URL).
    var playlistURL: URL
    /// What the streamer speaks, and what to show.
    var language: String
    var target: String
  }

  private var task: Task<Void, Never>?

  /// - Parameters:
  ///   - translate: turns a finished sentence into the viewer's language (nil: show it as is).
  ///   - show: the caption to show (or a status line), nil to clear.
  ///   - finished: each finished sentence, translated (for reading it out).
  func start(
    _ setup: Setup, translate: @escaping @Sendable (String) async -> String?,
    show: @escaping @MainActor @Sendable (String?) -> Void,
    finished: @escaping @MainActor @Sendable (String) -> Void = { _ in }
  ) {
    stop()
    #if compiler(>=6.2)
      #if canImport(Speech) && !KESTREL_NO_CAPTIONS
        if #available(iOS 26.0, *) {
          task = Task.detached(priority: .userInitiated) {
            await CaptionPipeline.run(setup, translate: translate, show: show, finished: finished)
          }
          return
        }
      #endif
    #endif
    show("Live captions need iOS 26")
  }

  func stop() {
    task?.cancel()
    task = nil
  }
}

/// Decodes a segment's AAC audio (ADTS) to PCM in the format speech recognition wants.
final class ADTSDecoder {
  let output: AVAudioFormat
  private var converter: AVAudioConverter?
  private var input: AVAudioFormat?
  private let file = FileManager.default.temporaryDirectory.appendingPathComponent("kestrel-captions-\(UUID().uuidString).aac")

  init(output: AVAudioFormat) {
    self.output = output
  }

  deinit {
    try? FileManager.default.removeItem(at: file)
  }

  func decode(_ adts: Data) -> AVAudioPCMBuffer? {
    do {
      // Apple's audio file reader understands ADTS directly.
      try adts.write(to: file, options: .atomic)
      let audio = try AVAudioFile(forReading: file)
      let format = audio.processingFormat
      let frames = AVAudioFrameCount(max(0, audio.length))
      guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
      try audio.read(into: pcm)
      if converter == nil || input != format {
        converter = AVAudioConverter(from: format, to: output)
        input = format
      }
      guard let converter, pcm.frameLength > 0 else { return nil }
      let ratio = output.sampleRate / format.sampleRate
      let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 4096
      guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
      var supplied = false
      var error: NSError?
      _ = converter.convert(to: converted, error: &error) { _, status in
        if supplied {
          status.pointee = .noDataNow  // more comes with the next segment
          return nil
        }
        supplied = true
        status.pointee = .haveData
        return pcm
      }
      return converted.frameLength > 0 ? converted : nil
    } catch {
      return nil
    }
  }
}

#if compiler(>=6.2)
  #if canImport(Speech) && !KESTREL_NO_CAPTIONS
    @available(iOS 26.0, *)
    private enum CaptionPipeline {
      static func run(
        _ setup: LiveCaptions.Setup, translate: @escaping @Sendable (String) async -> String?,
        show: @escaping @MainActor @Sendable (String?) -> Void,
        finished: @escaping @MainActor @Sendable (String) -> Void
      ) async {
        let name = LanguageGuess.name(setup.language)
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
          _ = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
          }
        }
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = pickLocale(setup.language, from: supported) else {
          await show("Live captions don't support \(name) yet")
          ActivityLog.shared.add("Live captions: \(name) isn't supported by on-device speech recognition")
          return
        }
        let transcriber = SpeechTranscriber(
          locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        do {
          if let request = optional(try await AssetInventory.assetInstallationRequest(supporting: [transcriber])) {
            await show("Downloading speech recognition for \(name)…")
            try await request.downloadAndInstall()
          }
        } catch {
          await show("Couldn't get speech recognition for \(name)")
          ActivityLog.shared.add("Live captions: speech model for \(name) failed (\(error.localizedDescription))")
          return
        }
        guard !Task.isCancelled else { return }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = optional(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])) else {
          await show("Live captions couldn't start")
          return
        }
        let (inputs, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        do {
          try await analyzer.start(inputSequence: inputs)
        } catch {
          await show("Live captions couldn't start")
          ActivityLog.shared.add("Live captions: \(error.localizedDescription)")
          return
        }
        let translating = LanguageGuess.base(setup.language) != setup.target
        await show(translating ? "Listening: \(name) → \(LanguageGuess.name(setup.target))…" : "Listening…")
        ActivityLog.shared.add("Live captions: \(locale.identifier)" + (translating ? " → \(setup.target)" : ""))

        let results = Task {
          var lines: [String] = []
          do {
            for try await result in transcriber.results {
              let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
              guard !text.isEmpty else { continue }
              if result.isFinal {
                let shown = translating ? (await translate(text) ?? text) : text
                lines.append(shown)
                if lines.count > 2 { lines.removeFirst(lines.count - 2) }
                await show(lines.joined(separator: " "))
                await finished(shown)
              } else if !translating {
                // Same language: words appear as they're recognized.
                await show((lines.suffix(1) + [text]).joined(separator: " "))
              }
            }
          } catch {
            if !Task.isCancelled { ActivityLog.shared.add("Live captions stopped: \(error.localizedDescription)") }
          }
        }

        let decoder = ADTSDecoder(output: format)
        let audio = LiveAudioFeed(playlistURL: setup.playlistURL, http: URLSessionHTTPClient(timeout: 8))
        await audio.run { data in
          if let buffer = decoder.decode(data) { feed.yield(AnalyzerInput(buffer: buffer)) }
        }
        // Switched off, or the stream ended.
        feed.finish()
        try? await analyzer.cancelAndFinishNow()
        results.cancel()
      }

      /// Same whether an API hands back an optional or not.
      private static func optional<T>(_ value: T?) -> T? { value }

      /// The supported variant of the stream's language, preferring this iPhone's region.
      static func pickLocale(_ code: String, from supported: [Locale]) -> Locale? {
        let language = Locale(identifier: code).language.languageCode?.identifier
        let matches = supported.filter { $0.language.languageCode?.identifier == language }
        if let region = Locale.current.region?.identifier, let local = matches.first(where: { $0.region?.identifier == region }) {
          return local
        }
        let usual = ["en": "US", "es": "ES", "fr": "FR", "de": "DE", "pt": "BR", "it": "IT", "ja": "JP", "ko": "KR", "zh": "CN"]
        if let language, let region = usual[language], let match = matches.first(where: { $0.region?.identifier == region }) {
          return match
        }
        return matches.first
      }
    }
  #endif
#endif
