// Kestrel's sound: the stream's AAC decoded here and played through AVAudioEngine, with a
// time-pitch unit for the speed.
//
// It replaces AVSampleBufferAudioRenderer, which cut the sound for a moment at every change of
// speed (the player speeds up a little to catch up with live, and slows down to build its margin
// back). AVAudioUnitTimePitch is made to change speed while it plays, without a break.
//
// The sound is the player's clock: `position` is the stream time being heard right now, and the
// picture follows it (see KestrelEngine.syncClock).

import AVFoundation

@MainActor
final class AudioOutput {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let pitch = AVAudioUnitTimePitch()
  /// The audio compressor (like FrankerFaceZ's): loud moments brought down, quiet ones up, so a
  /// streamer's shouting and whispering come out at about the same level. Off: passed through.
  private let compressor = AVAudioUnitEffect(
    audioComponentDescription: AudioComponentDescription(
      componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
      componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))

  /// UserDefaults key for the compressor setting, and the notice sent when it changes.
  static let compressorKey = "audioCompressor"
  static let compressorChanged = Notification.Name("KestrelAudioCompressorChanged")
  private var converter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?
  private var config: ADTS.Config?
  private(set) var outputFormat: AVAudioFormat?
  /// What's been scheduled, in order: each buffer's first sample on the player's timeline (from
  /// when it last started), its length, and its stream time (90 kHz).
  private var scheduled: [(sample: Int64, frames: Int64, pts: Int64)] = []
  private var scheduledEnd: Int64 = 0
  /// Stream times of decoder input not yet out of the decoder (it may hold a frame or two).
  private var pendingInput: [Int64] = []
  private(set) var isPlaying = false
  private var speed: Float = 1
  private var volume: Float = 1
  private var muted = false
  private var observers: [NSObjectProtocol] = []
  /// Called when the system stopped the sound (a route change, an interruption) and it was started
  /// again: what was scheduled is gone, and the player hands back what it still has.
  var onReset: (() -> Void)?

  static let clock: Int64 = 90_000

  init() {
    engine.attach(player)
    engine.attach(pitch)
    engine.attach(compressor)
    configureCompressor()
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.restartAfterSystemStop() }
      })
    observers.append(
      center.addObserver(forName: Self.compressorChanged, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.configureCompressor() }
      })
    #if os(iOS) || os(tvOS)
      observers.append(
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
          let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
          let ended = raw.flatMap { AVAudioSession.InterruptionType(rawValue: $0) } == .ended
          MainActor.assumeIsolated { if ended { self?.restartAfterSystemStop() } }
        })
    #endif
  }

  // MARK: Decoding and scheduling

  /// Decodes one AAC frame and queues its sound (in the order handed in, back to back).
  func enqueue(_ frame: AudioFrame, pts: Int64) {
    guard prepare(for: frame.config), let converter, let inputFormat, let outputFormat else { return }
    let data = frame.data
    guard !data.isEmpty else { return }
    let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: data.count)
    data.withUnsafeBytes { bytes in
      compressed.data.copyMemory(from: bytes.baseAddress!, byteCount: data.count)
    }
    compressed.byteLength = UInt32(data.count)
    compressed.packetCount = 1
    compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
      mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))
    pendingInput.append(pts)
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { return }
    var supplied = false
    var error: NSError?
    _ = converter.convert(to: output, error: &error) { _, status in
      if supplied {
        status.pointee = .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return compressed
    }
    guard error == nil, output.frameLength > 0 else { return }
    // The decoder's output, matched to the stream time of the oldest frame it still had, and as
    // many frames used up as came out (it sometimes gives two at once: counted as one, the times
    // fell behind by a frame each time, the sound read as off the picture and was re-synced every
    // couple of seconds, a gap each time).
    guard let outPTS = pendingInput.first else { return }
    let used = max(1, Int((Double(output.frameLength) / 1024).rounded()))
    pendingInput.removeFirst(min(used, pendingInput.count))
    if pendingInput.count > 4 { pendingInput.removeFirst(pendingInput.count - 4) }
    schedule(output, pts: outPTS)
  }

  private func schedule(_ buffer: AVAudioPCMBuffer, pts: Int64) {
    // Run dry meanwhile: the next buffer plays as soon as it's scheduled, so it starts at the
    // player's current sample, not where the last one ended.
    if let now = playerSample, now > scheduledEnd { scheduledEnd = now }
    let frames = Int64(buffer.frameLength)
    scheduled.append((scheduledEnd, frames, pts))
    scheduledEnd += frames
    player.scheduleBuffer(buffer, completionHandler: nil)
    if scheduled.count > 400 { scheduled.removeFirst(scheduled.count - 400) }
  }

  /// A converter (and the engine's connections) for this stream's sound.
  private func prepare(for newConfig: ADTS.Config) -> Bool {
    if newConfig == config, converter != nil { return true }
    var description = AudioStreamBasicDescription(
      mSampleRate: Float64(newConfig.sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: UInt32(newConfig.objectType),
      mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(newConfig.channels),
      mBitsPerChannel: 0, mReserved: 0)
    guard let input = AVAudioFormat(streamDescription: &description),
      let output = AVAudioFormat(standardFormatWithSampleRate: Double(newConfig.sampleRate), channels: AVAudioChannelCount(max(1, min(newConfig.channels, 2)))),
      let newConverter = AVAudioConverter(from: input, to: output)
    else { return false }
    newConverter.magicCookie = KestrelEngine.esds(newConfig.audioSpecificConfig)
    let formatChanged = output != outputFormat
    converter = newConverter
    inputFormat = input
    config = newConfig
    pendingInput = []
    if formatChanged {
      let wasPlaying = isPlaying
      stopPlayer()
      engine.disconnectNodeOutput(player)
      engine.disconnectNodeOutput(pitch)
      engine.disconnectNodeOutput(compressor)
      engine.connect(player, to: pitch, format: output)
      engine.connect(pitch, to: compressor, format: output)
      engine.connect(compressor, to: engine.mainMixerNode, format: output)
      outputFormat = output
      if wasPlaying { play() }
    }
    return true
  }

  // MARK: Compressor

  /// On or off from the setting; settings near FrankerFaceZ's: from -30 dB, a firm ratio, fast
  /// attack, quarter-second release, and the level made up after.
  private func configureCompressor() {
    let on = UserDefaults.standard.bool(forKey: Self.compressorKey)
    compressor.bypass = !on
    let unit = compressor.audioUnit
    func set(_ parameter: AudioUnitParameterID, _ value: AudioUnitParameterValue) {
      AudioUnitSetParameter(unit, parameter, kAudioUnitScope_Global, 0, value, 0)
    }
    set(kDynamicsProcessorParam_Threshold, -30)
    set(kDynamicsProcessorParam_HeadRoom, 4)
    set(kDynamicsProcessorParam_AttackTime, 0.003)
    set(kDynamicsProcessorParam_ReleaseTime, 0.25)
    set(kDynamicsProcessorParam_OverallGain, 6)
  }

  // MARK: Playing

  /// Starts (or resumes) the sound at the current speed.
  func play() {
    guard outputFormat != nil else { return }
    activateSession()
    if !engine.isRunning {
      engine.prepare()
      do { try engine.start() } catch {
        ActivityLog.shared.add("Kestrel player: the sound didn't start (\(error.localizedDescription))")
        return
      }
    }
    pitch.rate = max(1 / 32, speed)
    player.play()
    isPlaying = true
  }

  /// Holds the sound where it is (it goes on from the same place).
  func pause() {
    player.pause()
    isPlaying = false
  }

  /// The speed (pitch kept): changes smoothly while it plays.
  func setSpeed(_ rate: Float) {
    speed = rate
    if rate > 0 { pitch.rate = rate }
  }

  /// Drops everything queued (a new start, a restart).
  func flush() {
    stopPlayer()
    converter?.reset()
    pendingInput = []
  }

  private func stopPlayer() {
    player.stop()
    isPlaying = false
    scheduled = []
    scheduledEnd = 0
  }

  func shutDown() {
    flush()
    engine.stop()
  }

  func setMuted(_ mute: Bool) {
    muted = mute
    player.volume = mute ? 0 : volume
  }

  func setVolume(_ value: Float) {
    volume = value
    if !muted { player.volume = value }
  }

  // MARK: The clock

  /// The player's current sample (since it last started), while it's running.
  private var playerSample: Int64? {
    guard isPlaying, let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
      let time = player.playerTime(forNodeTime: nodeTime)
    else { return nil }
    return time.sampleTime
  }

  /// The stream time being heard now (90 kHz), or nil while nothing's playing.
  var position: Int64? {
    guard let sample = playerSample, let format = outputFormat, let first = scheduled.first else { return nil }
    let rate = format.sampleRate
    var entry = first
    // The buffer playing now (the newest one that started at or before this sample).
    if let index = scheduled.lastIndex(where: { $0.sample <= sample }) {
      entry = scheduled[index]
      if index > 50 { scheduled.removeFirst(index - 50) }
    }
    let into = min(sample - entry.sample, entry.frames)
    var media = entry.pts + Int64(Double(into) / rate * Double(Self.clock))
    // What's heard is behind what was just rendered: the output's latency, and the pitch unit's.
    let behind = outputLatency * Double(speed)
    media -= Int64(behind * Double(Self.clock))
    return media
  }

  /// Seconds between rendering and hearing.
  private var outputLatency: Double {
    var seconds = pitch.auAudioUnit.latency
    #if os(iOS) || os(tvOS)
      let session = AVAudioSession.sharedInstance()
      seconds += session.outputLatency + session.ioBufferDuration
    #endif
    return seconds
  }

  /// Sound queued but not yet heard (seconds).
  var queuedAhead: Double {
    guard let format = outputFormat else { return 0 }
    let now = playerSample ?? 0
    return max(0, Double(scheduledEnd - now) / format.sampleRate)
  }

  // MARK: System

  private func activateSession() {
    #if os(iOS) || os(tvOS)
      try? AVAudioSession.sharedInstance().setActive(true)
    #endif
  }

  /// The system stopped the engine (headphones in or out, AirPlay, a call): start it again and
  /// have the player hand back what's still to come.
  private func restartAfterSystemStop() {
    let wasPlaying = isPlaying
    stopPlayer()
    converter?.reset()
    pendingInput = []
    if let format = outputFormat {
      engine.disconnectNodeOutput(player)
      engine.disconnectNodeOutput(pitch)
      engine.disconnectNodeOutput(compressor)
      engine.connect(player, to: pitch, format: format)
      engine.connect(pitch, to: compressor, format: format)
      engine.connect(compressor, to: engine.mainMixerNode, format: format)
    }
    ActivityLog.shared.add("Kestrel player: the sound was stopped by the system; started again")
    onReset?()
    if wasPlaying { play() }
  }
}
