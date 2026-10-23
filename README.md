# Kestrel

An iOS client for watching Twitch without ads, with low-latency playback, chat and your follows.

## Features

- **Ad-free streams through ad-free servers** (Settings → Ad blocking, on by default). Kestrel asks one of the [TTV LOL PRO v1 servers](https://wiki.cdn-perfprod.com/v1/must-read/proxies) (PerfProd / Luminous) for the stream. The server requests it from a country where Twitch doesn't run ads and hands back the playlist; the video itself still comes straight from Twitch at full quality.
  - "Automatic" tries the servers in order, starting with the last one that worked; you can also pin one server.
  - Alternatives: "My own proxy" (an HTTP proxy of yours in an ad-free country; only Twitch's playback requests go through it), or "Basic" (no server: client-side breaks are skipped, stitched-in ads are swapped for an ad-free copy of the stream or hidden).
  - Signed in and subscribed to the channel (or with Turbo), Twitch shows you no ads: Kestrel checks that first and then plays straight from Twitch, with every quality (including sub-only and signed-in 1440p) and Twitch's own low latency.
  - As a safety net the player still strips ad markers and, if an ad is stitched in anyway, switches to an ad-free copy (the TwitchAdSolutions/vaft technique). Prefetched segments are held back during announced breaks so an ad doesn't flash on screen.
- **Player, Twitch-style:**
  - Tap the video for controls; they fade out on their own. The gear holds **Quality**, **Low latency** and **Video stats**.
  - **Gestures:** double-tap for full screen (in landscape: zoom to fill / fit); pinch to fill or fit; swipe up for full screen; pull the video down to shrink it into the **mini player** (it follows your finger); in landscape, swipe down to leave full screen and left/right to show or hide chat.
  - **Mini player:** keeps playing in the corner above the tab bar while you browse. Tap or drag it up to open, pause or close it with its buttons, or throw it aside to close.
  - **Landscape:** the video only keeps clear of the Dynamic Island; chat sits beside it and runs to the screen edge on the other side (toggle with the chat button or a swipe, drag the line between them to resize). The player turns with the phone; the full-screen button holds landscape until you turn the phone.
  - **Rewind live streams:** when the channel records a VOD of the broadcast (and it plays for you), a seek bar runs from the start of the stream to now. Drag back to watch from any point; tap LIVE or drag to the end to return. Channels without that VOD don't get the bar.
  - **VOD seek previews:** dragging the seek bar shows a thumbnail of where you'll land (Twitch's storyboards), on VODs and live rewinds; the other controls step aside while you drag.
- **VODs:**
  - Start at the beginning, or where you left off: positions are saved on the iPhone and, signed in, to your Twitch account the way Twitch's player does, so the website and apps resume at the same point. Channel video lists show how far you got.
  - **Chat replay** in time with the video.
  - Parts Twitch muted for copyright play (silently) instead of freezing: Twitch lists them under file names that don't exist, and Kestrel corrects them like Twitch's own player.
  - A VOD of a stream that's still live shows "RECORDING" and its seek bar grows as it records.
  - One layout for both orientations, so rotating, opening chat, the keyboard and the emote picker all animate instead of rebuilding the player.
  - Picture in Picture, AirPlay, background audio, tap LIVE to jump back to the live edge.
- **Low latency:** the [Amazon IVS Player SDK](https://docs.aws.amazon.com/ivs/latest/LowLatencyUserGuide/player-ios.html) (the engine Twitch's own apps use) in Twitch's low-latency mode, usually a few seconds behind. Falls back to the Apple player (AVPlayer, ~8–12 s behind) if it can't play a stream. Only in builds made with the SDK (the GitHub Actions build downloads it). VODs use the Apple player.
- **Highest quality, always:** the top rendition is picked and kept. Kestrel asks Twitch for every codec the iPhone decodes in hardware, so channels using Enhanced Broadcasting list their HEVC/AV1 1440p renditions; renditions the low-latency player can't decode appear as "· Apple player". Twitch only offers 1440p to some signed-in viewers in some regions.
- **Sign in with Twitch** (optional) on Twitch's own login page inside the app:
  - **Chat as yourself**, with room-mode notices (slow, followers-only, sub-only); tap a name to mention it.
  - **Emote picker** (smiley button): every emote you can use in this channel — the channel's sub and follower emotes you have, your other subs, Twitch's, and the channel's 7TV/BTTV/FFZ emotes — with Recent first.
  - **Autocomplete:** type `:` and a few letters for emotes, `@` for people in chat.
  - **Following** shows your Twitch follows, live channels first (sorted by viewers) and offline ones with when they were last live. Channels you heart in the player are added too.
- **Chat:** Twitch, 7TV, BTTV and FFZ emotes (animated), badges, and recent messages when you join.
- **Video stats:** a Twitch-style overlay with player, quality, codecs, resolution, frame rate, bitrate, bandwidth, buffer, latency, dropped frames, ad state and ad-blocking route.

**Settings → Activity log** shows which ad-free server delivered each stream (and where Twitch thinks you are), ad breaks, player fallbacks, and image hosts that fail to load.

## Install

Download `Kestrel.ipa` from the latest GitHub Actions run (**Actions → Build IPA → Artifacts**) and sideload it with your usual tool (SideStore, AltStore, Feather, TrollStore…). Requires iOS 16+.

## Build

**GitHub Actions** (no Mac needed): push to your repo. The `Build IPA` workflow installs a Linux iOS toolchain and the iOS 16.5 SDK, downloads the Amazon IVS Player SDK (pinned version, SHA-256 checked), runs `./build.sh`, and uploads the IPA. If the SDK can't be downloaded or linked, it builds without the low-latency player and flags a warning on the run.

**Locally:**
- Linux: install the Theos iOS toolchain at `~/theos` (the same layout the workflow creates), then run `./build.sh`.
- macOS with Xcode: just run `./build.sh`.
- For the low-latency player, unpack `https://player.live-video.net/<version>/AmazonIVSPlayer.xcframework.zip` into `vendor/` (or set `IVS_XCFRAMEWORK`).

**Core tests** (playlist parsing, ad handling against a simulated Twitch and ad-free server, the local server, chat parsing): `./Tests/run.sh`. Needs a host Swift toolchain (Linux or macOS).

## Layout

| Path | What |
|---|---|
| `Sources/Core/AdFreeProxy.swift` | The ad-free servers and how they're asked for a stream |
| `Sources/Core/HLS.swift` | Playlist parsing, ad markers |
| `Sources/Core/StreamSession.swift`, `LowLatencySession.swift` | Ad handling for the Apple and low-latency players |
| `Sources/Core/LocalHTTPServer.swift` | Localhost server the players load playlists from |
| `Sources/Twitch/` | GraphQL API, sign-in, playback tokens, follows, chat/IRC, third-party emotes |
| `Sources/App/` | SwiftUI app: player screen and controls, players, chat (UIKit list with animated emotes), images |

## Limitations

- The ad-free servers are run by third parties (PerfProd, Luminous). They see which channel you open, not your Twitch login; if none answers, Kestrel falls back to Basic ad blocking.
- Streams fetched through an ad-free server are requested anonymously, so 1440p that Twitch reserves for signed-in viewers may not be listed there (channels you're subscribed to play straight from Twitch and keep it). Switch Ad blocking to Basic if you'd rather have it everywhere.
- Following and unfollowing on Twitch itself isn't possible from Kestrel (Twitch requires its own app for that); the heart adds a channel to Kestrel's list.
- The Amazon IVS Player SDK isn't open source; it's distributed by AWS under its own terms and isn't included in this repository.

## Credits

Ad-free servers: [TTV LOL PRO](https://github.com/younesaassila/ttv-lol-pro) v1 list (PerfProd, [luminous-ttv](https://github.com/AlyoshaVasilieva/luminous-ttv)). Ad markers and the backup-stream approach: [TwitchAdSolutions](https://github.com/ryanbr/TwitchAdSolutions) (MIT) and [streamlink](https://github.com/streamlink/streamlink)'s Twitch plugin (BSD-2). GraphQL query shapes follow [Xtra](https://github.com/crackededed/Xtra). Not affiliated with Twitch.
