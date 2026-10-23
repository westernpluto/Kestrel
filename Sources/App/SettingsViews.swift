import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var settings: AppSettings
  @State private var imageCacheCleared = false

  var body: some View {
    Form {
      Section {
        Toggle("Switch to ad-free copy", isOn: $settings.backupStreams)
        Toggle("Allow 360p during ads", isOn: $settings.allowLowQualityBackup)
          .disabled(!settings.backupStreams)
        Picker("If no ad-free copy", selection: $settings.adFallback) {
          Text("Hide & mute the ad").tag(AdFallback.muteAndCover)
          Text("Pause until it's over").tag(AdFallback.wait)
        }
      } header: {
        Text("Ad blocking")
      } footer: {
        Text("When an ad starts, Kestrel fetches other copies of the same stream in the background and switches to one without the ad. 360p copies are only used if no full-quality copy is ad-free. Changes apply to the next stream you open.")
      }

      Section {
        if PlayerEngine.available.count > 1 {
          Picker("Live player", selection: $settings.playerEngine) {
            ForEach(PlayerEngine.available) { Text($0.title).tag($0) }
          }
          Toggle("Twitch low-latency mode", isOn: $settings.lowLatency)
            .disabled(settings.playerEngine != .lowLatency)
          Toggle("1440p over low latency", isOn: $settings.highestQualityOverLatency)
            .disabled(settings.playerEngine != .lowLatency)
        } else {
          LabeledContent("Live player", value: PlayerEngine.standard.title)
        }
      } header: {
        Text("Live player")
      } footer: {
        Text(
          PlayerEngine.isLowLatencyBuilt
            ? "Low-latency player: Amazon IVS, the engine Twitch's own apps are built on, in Twitch's low-latency mode (usually a few seconds behind). If it can't play a stream, Kestrel switches to the Apple player. Some 1440p streams use a format it can't decode: they're listed in the quality menu as “· Apple player”, and with “1440p over low latency” on, Kestrel switches to the Apple player for them by itself. Apple player: AVPlayer with Picture in Picture and AirPlay, roughly 8–12 s behind, and swaps in an ad-free copy if an ad is stitched into the stream. Client-side ads (how Twitch serves most ads now) never play in either. You can also switch from the player screen."
            : "This build doesn't include the low-latency player (the GitHub Actions build adds the Amazon IVS SDK it needs). The Apple player stays roughly 8–12 s behind live.")
      }

      Section {
        Toggle("Enhanced quality (HEVC/AV1)", isOn: $settings.enhancedCodecs)
        Toggle("Keep audio in background", isOn: $settings.backgroundAudio)
      } header: {
        Text("Playback")
      } footer: {
        Text("Streams always start at the highest quality and stay there; pick another in the player's menu for just that stream. Enhanced quality asks Twitch for HEVC/AV1 renditions (this device decodes \(DeviceCodecs.summary)), which is how 1440p is delivered on channels using Enhanced Broadcasting. Most channels top out at 1080p60. Applies to the next stream you open.")
      }

      Section("Chat") {
        Toggle("Show chat", isOn: $settings.chatEnabled)
        Toggle("7TV, BTTV & FFZ emotes", isOn: $settings.thirdPartyEmotes)
        Toggle("Timestamps", isOn: $settings.chatTimestamps)
        Stepper(value: $settings.chatFontSize, in: 12...22, step: 1) {
          Text("Text size \(Int(settings.chatFontSize))")
        }
      }

      Section {
        NavigationLink("Activity log") { ActivityLogView() }
        Button(imageCacheCleared ? "Image cache cleared" : "Clear image cache") {
          ImageCache.shared.clear()
          imageCacheCleared = true
        }
        .disabled(imageCacheCleared)
      } footer: {
        Text("Kestrel \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · watching anonymously. Follows are stored on this device.")
      }
    }
    .navigationTitle("Settings")
  }
}

final class ActivityLogModel: ObservableObject {
  @Published var entries: [ActivityLog.Entry] = ActivityLog.shared.all.reversed()

  init() {
    ActivityLog.shared.onChange = { [weak self] in
      guard let model = self else { return }
      DispatchQueue.main.async { model.entries = ActivityLog.shared.all.reversed() }
    }
  }

  deinit { ActivityLog.shared.onChange = nil }
}

struct ActivityLogView: View {
  @StateObject private var model = ActivityLogModel()
  private static let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
  }()

  var body: some View {
    List {
      if model.entries.isEmpty {
        Text("Nothing yet. Open a stream: ad breaks and how they were handled show up here.")
          .foregroundColor(.secondary)
      }
      ForEach(model.entries) { entry in
        VStack(alignment: .leading, spacing: 2) {
          Text(Self.formatter.string(from: entry.date)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
          Text(entry.message).font(.footnote)
        }
      }
    }
    .navigationTitle("Activity log")
    .toolbar {
      ToolbarItemGroup(placement: .navigationBarTrailing) {
        Button {
          UIPasteboard.general.string = model.entries.reversed()
            .map { "\(Self.formatter.string(from: $0.date))  \($0.message)" }.joined(separator: "\n")
        } label: {
          Image(systemName: "doc.on.doc")
        }
        Button("Clear") { ActivityLog.shared.clear() }
      }
    }
  }
}
