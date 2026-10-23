// Live captions of what the streamer says, translated when the stream is in another language.
// Experimental, iOS 26: the stream's audio-only rendition is followed separately (LiveAudioFeed),
// decoded, and fed to Apple's on-device speech recognition (SpeechAnalyzer); what it hears is
// translated on the iPhone (ChatTranslator) and shown over the video. Nothing is sent anywhere.
// The first time, iOS downloads the speech model for the stream's language (a system download
// shared with other apps, not part of Kestrel).
//
// Every stage reports how it's going on the caption line (and in Settings → Activity log), so
// when captions don't appear it's clear where they stopped.

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

  struct Callbacks: Sendable {
    /// Turns text into the viewer's language (nil: show it as is).
    var translate: @Sendable (String) async -> String?
    /// A caption to show (fades after a while).
    var caption: @MainActor @Sendable (String) -> Void
    /// How it's going ("Downloading…", "Listening…", a problem); stays until replaced.
    var status: @MainActor @Sendable (String?) -> Void
    /// Each finished sentence, translated (for reading it out).
    var finished: @MainActor @Sendable (String) -> Void
  }

  private var task: Task<Void, Never>?

  func start(_ setup: Setup, _ callbacks: Callbacks) {
    stop()
    #if compiler(>=6.2)
      #if canImport(Speech) && !KESTREL_NO_CAPTIONS
        if #available(iOS 26.0, *) {
          task = Task.detached(priority: .userInitiated) {
            await CaptionPipeline.run(setup, callbacks)
          }
          return
        }
      #endif
    #endif
    callbacks.status("Live captions need iOS 26")
  }

  func stop() {
    task?.cancel()
    task = nil
  }

  /// Lets iOS delete the speech models Kestrel asked for (they're system downloads, shared with
  /// other apps). Returns how many languages were let go.
  static func releaseSpeechModels() async -> Int {
    #if compiler(>=6.2)
      #if canImport(Speech) && !KESTREL_NO_CAPTIONS
        if #available(iOS 26.0, *) {
          var released = 0
          for locale in await AssetInventory.reservedLocales {
            if await AssetInventory.release(reservedLocale: locale) { released += 1 }
          }
          return released
        }
      #endif
    #endif
    return 0
  }
}

/// Turns a segment's audio into PCM in the format speech recognition wants: AAC with ADTS
/// headers (from MPEG-TS) through Apple's audio file reader, fragmented MP4 through AVFoundation's
/// asset reader.
final class AudioChunkDecoder {
  let output: AVAudioFormat
  private var converter: AVAudioConverter?
  private var input: AVAudioFormat?
  private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kestrel-captions-\(UUID().uuidString)")
  /// Why the last chunk couldn't be decoded (for the status line).
  private(set) var lastProblem: String?

  init(output: AVAudioFormat) {
    self.output = output
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: folder)
  }

  func decode(_ chunk: LiveAudioChunk) async -> AVAudioPCMBuffer? {
    let pcm: AVAudioPCMBuffer?
    switch chunk {
    case .adts(let data): pcm = decodeADTS(data)
    case .fragmentedMP4(let initialization, let segment): pcm = await decodeMP4(initialization + segment)
    }
    guard let pcm, pcm.frameLength > 0 else { return nil }
    return convert(pcm)
  }

  private func decodeADTS(_ data: Data) -> AVAudioPCMBuffer? {
    let file = folder.appendingPathComponent("segment.aac")
    do {
      try data.write(to: file, options: .atomic)
      let audio = try AVAudioFile(forReading: file)
      let frames = AVAudioFrameCount(max(0, audio.length))
      guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: frames) else {
        lastProblem = "empty audio segment"
        return nil
      }
      try audio.read(into: pcm)
      return pcm
    } catch {
      lastProblem = "AAC: \(error.localizedDescription)"
      return nil
    }
  }

  private func decodeMP4(_ data: Data) async -> AVAudioPCMBuffer? {
    let file = folder.appendingPathComponent("segment.mp4")
    do {
      try data.write(to: file, options: .atomic)
      let asset = AVURLAsset(url: file)
      guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
        lastProblem = "no audio track in the segment"
        return nil
      }
      let reader = try AVAssetReader(asset: asset)
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
      ]
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
      reader.add(output)
      guard reader.startReading() else {
        lastProblem = "MP4: \(reader.error?.localizedDescription ?? "can't read")"
        return nil
      }
      var samples = Data()
      var sampleRate = 0.0
      var channels: AVAudioChannelCount = 0
      while let buffer = output.copyNextSampleBuffer() {
        if sampleRate == 0, let description = CMSampleBufferGetFormatDescription(buffer),
          let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        {
          sampleRate = basic.mSampleRate
          channels = AVAudioChannelCount(basic.mChannelsPerFrame)
        }
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: length)
        bytes.withUnsafeMutableBytes { raw in
          if let base = raw.baseAddress { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base) }
        }
        samples.append(bytes)
      }
      guard sampleRate > 0, channels > 0,
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: true)
      else {
        lastProblem = "MP4: no audio decoded"
        return nil
      }
      let frames = AVAudioFrameCount(samples.count / (MemoryLayout<Float>.size * Int(channels)))
      guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
      pcm.frameLength = frames
      samples.withUnsafeBytes { raw in
        if let source = raw.baseAddress, let destination = pcm.audioBufferList.pointee.mBuffers.mData {
          memcpy(destination, source, Int(frames) * MemoryLayout<Float>.size * Int(channels))
        }
      }
      return pcm
    } catch {
      lastProblem = "MP4: \(error.localizedDescription)"
      return nil
    }
  }

  private func convert(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let format = pcm.format
    if format == output { return pcm }
    if converter == nil || input != format {
      converter = AVAudioConverter(from: format, to: output)
      // No priming: the first samples suffer slightly, but there's no drift between segments.
      converter?.primeMethod = .none
      // Stereo stream, mono recognizer: mix both sides rather than dropping one.
      converter?.downmix = true
      input = format
    }
    guard let converter else {
      lastProblem = "can't convert \(format) to \(output)"
      return nil
    }
    let ratio = output.sampleRate / format.sampleRate
    let capacity = AVAudioFrameCount((Double(pcm.frameLength) * ratio).rounded(.up)) + 1024
    guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: converted, error: &error) { _, inputStatus in
      if supplied {
        inputStatus.pointee = .noDataNow  // more comes with the next segment
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return pcm
    }
    if status == .error {
      lastProblem = "conversion: \(error?.localizedDescription ?? "failed")"
      return nil
    }
    return converted.frameLength > 0 ? converted : nil
  }
}

/// Counts for the status line, shared between the audio and results tasks.
private final class CaptionCounters: @unchecked Sendable {
  private let lock = NSLock()
  private var _audioSeconds = 0.0
  private var _decodeFailures = 0
  private var _heard = false

  var audioSeconds: Double { lock.lock(); defer { lock.unlock() }; return _audioSeconds }
  var decodeFailures: Int { lock.lock(); defer { lock.unlock() }; return _decodeFailures }
  var heard: Bool { lock.lock(); defer { lock.unlock() }; return _heard }

  func fed(_ seconds: Double) { lock.lock(); _audioSeconds += seconds; lock.unlock() }
  func failed() { lock.lock(); _decodeFailures += 1; lock.unlock() }
  func heardSomething() { lock.lock(); _heard = true; lock.unlock() }
}

#if compiler(>=6.2)
  #if canImport(Speech) && !KESTREL_NO_CAPTIONS
    @available(iOS 26.0, *)
    private enum CaptionPipeline {
      static func run(_ setup: LiveCaptions.Setup, _ callbacks: LiveCaptions.Callbacks) async {
        let log = ActivityLog.shared
        let name = LanguageGuess.name(setup.language)
        let status = callbacks.status
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
          _ = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
          }
        }

        // 1. The speech model for the stream's language.
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = pickLocale(setup.language, from: supported) else {
          await status("Live captions don't support \(name) yet")
          log.add("Live captions: \(name) isn't supported by on-device speech recognition")
          return
        }
        log.add("Live captions: \(name) speech, as \(locale.identifier)")
        let transcriber = SpeechTranscriber(
          locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        do {
          _ = try await AssetInventory.reserve(locale: locale)
          if let request = optional(try await AssetInventory.assetInstallationRequest(supporting: [transcriber])) {
            await status("Downloading speech recognition for \(name)… (only the first time)")
            log.add("Live captions: downloading the \(name) speech model")
            try await request.downloadAndInstall()
            log.add("Live captions: \(name) speech model ready")
          }
        } catch {
          await status("Couldn't get speech recognition for \(name): \(error.localizedDescription)")
          log.add("Live captions: the \(name) speech model failed (\(error.localizedDescription))")
          return
        }
        guard !Task.isCancelled else { return }

        // 2. The analyzer, fed with the stream's audio.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = optional(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])) else {
          await status("Live captions couldn't start (no audio format for \(name))")
          log.add("Live captions: no audio format for \(locale.identifier)")
          return
        }
        log.add("Live captions: speech recognition takes \(format)")
        let (inputs, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        do {
          try await analyzer.start(inputSequence: inputs)
        } catch {
          await status("Live captions couldn't start: \(error.localizedDescription)")
          log.add("Live captions: the analyzer didn't start (\(error.localizedDescription))")
          return
        }
        let translating = LanguageGuess.base(setup.language) != setup.target
        let listening = translating ? "Listening: \(name) → \(LanguageGuess.name(setup.target))…" : "Listening…"
        await status(listening)
        let counters = CaptionCounters()

        // 3. What it hears.
        let results = Task {
          var lines: [String] = []
          var lastPreview = Date.distantPast
          var previewing = false
          do {
            for try await result in transcriber.results {
              let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
              guard !text.isEmpty else { continue }
              if !counters.heard {
                counters.heardSomething()
                log.add("Live captions: hearing speech")
              }
              if result.isFinal {
                let shown = translating ? (await callbacks.translate(text) ?? text) : text
                lines.append(shown)
                if lines.count > 2 { lines.removeFirst(lines.count - 2) }
                await callbacks.caption(lines.joined(separator: " "))
                await callbacks.finished(shown)
              } else if !translating {
                // Same language: words appear as they're recognized.
                await callbacks.caption((lines.suffix(1) + [text]).joined(separator: " "))
              } else if !previewing, Date().timeIntervalSince(lastPreview) > 1.5, text.count >= 12 {
                // Another language: the sentence so far, translated every so often, so captions
                // keep up with someone who never pauses.
                previewing = true
                lastPreview = Date()
                if let preview = await callbacks.translate(text) {
                  await callbacks.caption((lines.suffix(1) + [preview + " …"]).joined(separator: " "))
                }
                previewing = false
              }
            }
          } catch {
            if !Task.isCancelled {
              await status("Live captions stopped: \(error.localizedDescription)")
              log.add("Live captions stopped: \(error.localizedDescription)")
            }
          }
        }

        // 4. Until something's heard: say what's happening (or not).
        let watcher = Task {
          var reported = 0
          while !Task.isCancelled, !counters.heard {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, !counters.heard else { break }
            reported += 1
            let seconds = Int(counters.audioSeconds)
            if seconds > 0 {
              await status(listening + " (\(seconds) s of audio, no speech recognized yet)")
            } else if counters.decodeFailures > 0 {
              await status("Live captions: couldn't read the stream's audio")
            } else if reported >= 2 {
              await status("Live captions: waiting for the stream's audio…")
            }
          }
        }

        let decoder = AudioChunkDecoder(output: format)
        let audio = LiveAudioFeed(playlistURL: setup.playlistURL, http: URLSessionHTTPClient(timeout: 8))
        var reportedProblem = false
        await audio.run { chunk in
          if let buffer = await decoder.decode(chunk) {
            counters.fed(Double(buffer.frameLength) / buffer.format.sampleRate)
            feed.yield(AnalyzerInput(buffer: buffer))
          } else {
            counters.failed()
            if !reportedProblem {
              reportedProblem = true
              log.add("Live captions: couldn't decode the stream's audio (\(decoder.lastProblem ?? "unknown"))")
            }
          }
        }
        // Switched off, or the stream ended.
        watcher.cancel()
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
