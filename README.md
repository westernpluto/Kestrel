# Kestrel

An ad-free, low-latency Twitch client for **iPhone**, **Apple TV** and **Android**.

**[Download the latest release](../../releases/latest)**

## Features

- **No ads:** streams come through ad-free servers ([TTV LOL PRO](https://github.com/younesaassila/ttv-lol-pro) v1 list), your own proxy, or straight from Twitch when you're subscribed. Stitched-in ads are swapped for an ad-free copy.
- **Close to live:** Kestrel's own player plays each segment as it's made, about a second behind live, steering its speed to stay there. It adapts to weak connections.
- **Chat:** Twitch, 7TV, BTTV and FFZ emotes (animated), badges, recent messages, an emote picker, autocomplete, and Twitch's GIFs for Tier 2/3 subs.
- **Multi-view:** up to six streams at once, in one Picture in Picture window with play/pause.
- **Player:** mini player, Picture in Picture, AirPlay, background audio, rewind live streams, and an audio compressor.
- **VODs:** resume where you left off (synced with Twitch), chat replay, muted parts skipped.
- **Recordings:** record a stream now or whenever a channel goes live, and download VODs to watch offline.
- **Your account:** sign in with Twitch to chat, follow, and see your follows. Get alerts when they go live.
- **iPhone Duo:** layouts for both displays, either way up.

## Install

| File | For |
|---|---|
| `Kestrel-<version>.ipa` | iPhone and iPad, iOS 16+. Sideload with SideStore, AltStore, Feather or TrollStore. |
| `Kestrel-TV-<version>.ipa` | Apple TV. Sideload the same way. |
| `Kestrel-<version>.apk` | Android 8.0+. Open it on the phone to install. See [android/README.md](android/README.md). |

Builds between releases are under **Actions → Build IPA and APK → Artifacts**.

## Build

- **GitHub Actions:** every push builds all three apps. Push a `v*` tag, or tick **Publish this build as a GitHub release** under **Run workflow**, to publish a release.
- **Locally:** `./build.sh` (iPhone) and `./build-tv.sh` (Apple TV) need macOS with Xcode 27.1+. For the low-latency Amazon IVS player, unpack its xcframework into `vendor/`. Android: `gradle assembleRelease` in `android/`.
- **Tests:** `./Tests/run.sh` (any host Swift toolchain).

## Notes

- The ad-free servers are run by third parties. They see which channel you open, not your Twitch login.
- The Amazon IVS Player SDK is distributed by AWS under its own terms and isn't included here.
- Not affiliated with Twitch. Ad handling draws on [TwitchAdSolutions](https://github.com/ryanbr/TwitchAdSolutions) and [streamlink](https://github.com/streamlink/streamlink). GraphQL shapes follow [Xtra](https://github.com/crackededed/Xtra).
