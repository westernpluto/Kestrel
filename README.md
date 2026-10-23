# Kestrel

An iOS client for watching Twitch with ads blocked inside the player, low-latency playback and chat.

## Features

- **Browse** top live streams and categories, **search** channels and categories, **follow** channels (saved on the device), channel pages with past broadcasts and highlights.
- **Two live players** (Settings → Live player, or the button at the top of the player):
  - **Low-latency player** (default when included): built on the [Amazon IVS Player SDK](https://docs.aws.amazon.com/ivs/latest/LowLatencyUserGuide/player-ios.html), the engine Twitch's own apps are built on, in Twitch's low-latency mode. Picture in Picture; in the background it keeps playing the audio-only rendition (AWS doesn't officially support background playback, so the Apple player is the safer pick for long listening). If it can't play a stream it hands over to the Apple player automatically. Only in builds made with the SDK (the GitHub Actions build downloads it).
  - **Apple player**: AVPlayer with Picture in Picture, AirPlay and background audio, roughly 8–12 s behind live. Tap the latency readout to jump back to live after a stall.
  VODs always use the Apple player.
- **Always the highest quality** (live and VODs): the top rendition is picked and the player isn't allowed to step down on its own; the quality menu changes it for the current stream only.
- **1440p / HEVC / AV1:** Kestrel asks Twitch for every codec your iPhone decodes in hardware (Settings → Enhanced quality). Channels using Enhanced Broadcasting then list their HEVC/AV1 renditions (often 1440p60). Other channels top out at 1080p60, because that's all Twitch has for them. If a HEVC/AV1 rendition won't play, Kestrel retries with the next codec down.
- **Chat:** live read-only chat with Twitch, 7TV, BTTV and FFZ emotes, badges, and recent messages when you join.
- **Ads:**
  - *Client-side ads (how Twitch serves most ads in 2026):* the stream keeps carrying the real broadcast during a break, and only Twitch's own app fetches and plays the ad. Kestrel never fetches those ads, so these breaks are skipped with no switch, no gap and no quality change ("Ad skipped").
  - *Stitched-in ads* (rare now), Apple player: the app runs a tiny HTTP server on `127.0.0.1` and the player loads playlists from it. When an ad is stitched in, Kestrel fetches other copies of the same stream in parallel (other "player types": site, popout, mobile_web, embed, and 360p autoplay as a last resort) and switches to the first one without the ad, rebuilding the playlist so the switch is seamless (the TwitchAdSolutions/vaft technique). If no copy is ad-free, the ad is hidden behind a black card and muted.
  - *Stitched-in ads*, low-latency player: the player loads the same playback session through the local server, Kestrel watches that session's playlists, and hides and mutes the picture while an ad segment is on screen.
  - VODs have no stitched-in ads, and the app never requests any.

**Settings → Activity log** shows what happened in each ad break and any player fallbacks.

## Install

Download `Kestrel.ipa` from the latest GitHub Actions run (**Actions → Build IPA → Artifacts**) and sideload it with your usual tool (SideStore, AltStore, Feather, TrollStore…). Requires iOS 16+.

## Build

**GitHub Actions** (no Mac needed): push to your repo. The `Build IPA` workflow installs a Linux iOS toolchain and the iOS 16.5 SDK, downloads the Amazon IVS Player SDK (pinned version, SHA-256 checked against AWS's `Package.swift`), runs `./build.sh`, and uploads the IPA. If the SDK can't be downloaded or linked, it builds without the low-latency player and flags a warning on the run.

**Locally:**
- Linux: install the Theos iOS toolchain at `~/theos` (the same layout the workflow creates), then run `./build.sh`.
- macOS with Xcode: just run `./build.sh`.
- For the low-latency player, unpack `https://player.live-video.net/<version>/AmazonIVSPlayer.xcframework.zip` into `vendor/` (or set `IVS_XCFRAMEWORK`). `build.sh` links it and embeds it in `Frameworks/`; without it the app builds with the Apple player only.

**Core tests** (playlist parsing, the ad-break state machine against a simulated Twitch, the local server, chat parsing): `./Tests/run.sh`. Needs a host Swift toolchain (Linux or macOS).

## Layout

| Path | What |
|---|---|
| `Sources/Core/HLS.swift` | Playlist parsing, ad markers (stitched-ad DATERANGEs, `Amazon` titles, ad segment URLs) |
| `Sources/Core/Timeline.swift` | The synthesized playlist ("slots") |
| `Sources/Core/StreamSession.swift` | Ad-break handling and parallel backup search (Apple player) |
| `Sources/Core/LocalHTTPServer.swift` | Localhost server and routing |
| `Sources/Twitch/` | GraphQL API, playback tokens, chat/IRC parsing, third-party emotes |
| `Sources/App/` | SwiftUI app, players (`PlayerModel.swift`, `LowLatencyPlayer.swift`), UIKit chat list |

## Limitations

- No login yet: you can't send chat messages, and follows aren't synced with your Twitch account.
- Twitch changes its ad delivery from time to time. If ads get through, the Activity log shows which copies were tried.
- The Amazon IVS Player SDK isn't open source; it's distributed by AWS under its own terms. This repository doesn't include it: the build downloads it from AWS.

## Credits

Ad markers and the backup-stream approach come from [TwitchAdSolutions](https://github.com/ryanbr/TwitchAdSolutions) (MIT) and [streamlink](https://github.com/streamlink/streamlink)'s Twitch plugin (BSD-2). The GraphQL query shapes follow [Xtra](https://github.com/crackededed/Xtra). Not affiliated with Twitch.
