// Checks the watch player's MP4 files (MP4Writer) with Apple's own AVFoundation, on macOS: the
// files are made from real Twitch segments, then opened, every picture and sound sample decoded,
// and an AVPlayerItem made ready to play. ffmpeg (Tests/run.sh) is more forgiving than
// AVFoundation; a file AVFoundation won't take is skipped by the watch's AVQueuePlayer.
//   swiftc -parse-as-library Sources/Core/*.swift Sources/Twitch/*.swift Tests/AVCheck.swift -o avcheck
//   ./avcheck Tests/Fixtures

import AVFoundation
import Foundation

@main
struct AVCheck {
  static func main() async {
    let fixtures = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/Fixtures")
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("kestrel-avcheck", isDirectory: true)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var failures = 0
    for name in ["twitch_160p_segment.ts", "twitch_1080p_bframes.ts"] {
      guard let data = try? Data(contentsOf: fixtures.appendingPathComponent(name)) else {
        print("FAIL \(name): fixture missing")
        failures += 1
        continue
      }
      var demuxer = TSDemuxer()
      var video: [VideoFrame] = []
      var audio: [AudioFrame] = []
      for frame in demuxer.feed(data) + demuxer.flush() {
        switch frame {
        case .video(let v): video.append(v)
        case .audio(let a): audio.append(a)
        }
      }
      // (The 1080p fixture is cut off part-way through its last frame.)
      if name.contains("1080p"), !video.isEmpty { video.removeLast() }
      let first = video.map(\.pts).min() ?? 0
      print(String(format: "     %@: video %.3f-%.3f, audio %.3f-%.3f (stream times from the first picture)", name,
        0.0, Double((video.map(\.pts).max() ?? 0) - first + 3000) / 90_000,
        Double((audio.first?.pts ?? 0) - first) / 90_000, Double((audio.last?.pts ?? 0) - first + 1920) / 90_000))
      // (The segment's own first frames stand in for the previous file's last ones: their sound
      // is wrong, but what's measured is how much of it AVFoundation plays.)
      let three = Array(audio.prefix(3))
      let cases: [(String, MP4Writer.Segment)] = [
        ("plain", .init(video: video, audio: audio)),
        ("3 primers", .init(video: video, audio: audio, audioPrimers: three)),
      ]
      for (kind, segment) in cases {
        guard let mp4 = MP4Writer.file(segment) else {
          print("FAIL \(name) \(kind): no MP4")
          failures += 1
          continue
        }
        let file = out.appendingPathComponent("\(name).\(kind.replacingOccurrences(of: " ", with: "-")).mp4")
        try? mp4.write(to: file)
        let keyframe = video.firstIndex(where: \.isKeyframe) ?? 0
        print(String(format: "     %@ %@: %.3f s of sound in it", name, kind, Double(audio.count * 1024) / 48_000))
        if let problem = await check(file, videoFrames: video.count - keyframe, expectedSound: audio.count * 1024) {
          print("FAIL \(name) \(kind): \(problem)")
          failures += 1
        } else {
          print("ok   \(name) \(kind)")
        }
      }
    }
    print(failures == 0 ? "AVFoundation takes every file" : "\(failures) failures")
    exit(failures == 0 ? 0 : 1)
  }

  /// nil when AVFoundation plays it; else what's wrong.
  static func check(_ url: URL, videoFrames: Int, expectedSound: Int) async -> String? {
    let asset = AVURLAsset(url: url)
    do {
      guard try await asset.load(.isPlayable) else { return "not playable" }
      let duration = try await asset.load(.duration).seconds
      let videoTracks = try await asset.loadTracks(withMediaType: .video)
      let audioTracks = try await asset.loadTracks(withMediaType: .audio)
      guard let videoTrack = videoTracks.first, let audioTrack = audioTracks.first else {
        return "tracks: \(videoTracks.count) video, \(audioTracks.count) audio"
      }
      // Decoded, every sample: pictures to pixel buffers, sound to PCM.
      let reader = try AVAssetReader(asset: asset)
      let pictures = AVAssetReaderTrackOutput(
        track: videoTrack,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
      let sound = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
      reader.add(pictures)
      reader.add(sound)
      guard reader.startReading() else { return "reader: \(reader.error?.localizedDescription ?? "?")" }
      var pictureCount = 0
      while let sample = pictures.copyNextSampleBuffer() {
        if CMSampleBufferGetImageBuffer(sample) != nil { pictureCount += 1 }
      }
      var soundSamples = 0
      var soundStart: Double?
      var soundEnd = 0.0
      while let sample = sound.copyNextSampleBuffer() {
        soundSamples += CMSampleBufferGetNumSamples(sample)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        if soundStart == nil { soundStart = pts }
        soundEnd = pts + CMSampleBufferGetDuration(sample).seconds
      }
      print(String(format: "     decoded sound from %.3f to %.3f s", soundStart ?? -1, soundEnd))
      guard reader.status == .completed else { return "decoding: \(reader.error?.localizedDescription ?? "status \(reader.status.rawValue)")" }
      guard pictureCount >= videoFrames - 1 else { return "decoded \(pictureCount) of \(videoFrames) pictures" }
      let soundSeconds = Double(soundSamples) / 48_000
      if url.lastPathComponent.contains("3-primers") {
        let expected = Double(expectedSound) / 48_000
        guard abs(soundSeconds - expected) < 0.005 else { return String(format: "sound %.3f s of %.3f s played", soundSeconds, expected) }
        guard duration > expected - 0.005 else { return String(format: "file %.3f s long, sound %.3f s", duration, expected) }
      }
      // And ready to play in AVPlayer.
      let item = AVPlayerItem(asset: asset)
      let player = AVPlayer(playerItem: item)
      for _ in 0..<50 where item.status == .unknown { try? await Task.sleep(nanoseconds: 100_000_000) }
      guard item.status == .readyToPlay else { return "player item: \(item.error?.localizedDescription ?? "status \(item.status.rawValue)")" }
      _ = player
      print(String(format: "     %d pictures, %.3f s of sound, %.3f s long", pictureCount, soundSeconds, duration))
      return nil
    } catch {
      return error.localizedDescription
    }
  }
}
