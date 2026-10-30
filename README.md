# Kestrel

A client for watching Twitch without ads, with low-latency playback, chat and your follows: for iPhone, and for Android (see [android/README.md](android/README.md)).

## Features

- **Ad-free streams through ad-free servers** (Settings → Ad blocking, on by default). Kestrel asks one of the [TTV LOL PRO v1 servers](https://wiki.cdn-perfprod.com/v1/must-read/proxies) (PerfProd / Luminous) for the stream. The server requests it from a country where Twitch doesn't run ads and hands back the playlist; the video itself still comes straight from Twitch at full quality.
  - "Automatic" tries the servers in order, starting with the last one that worked; you can also pin one server.
  - Alternatives: "My own proxy" (an HTTP proxy of yours in an ad-free country; only Twitch's playback requests go through it), or "Basic" (no server: client-side breaks are skipped, stitched-in ads are swapped for an ad-free copy of the stream or hidden).
  - Signed in and subscribed to the channel (or with Turbo), Twitch shows you no ads: Kestrel checks that first and then plays straight from Twitch, with every quality (including sub-only and signed-in 1440p) and Twitch's own low latency.
  - As a safety net the player still strips ad markers and, if an ad is stitched in anyway, switches to an ad-free copy (the TwitchAdSolutions/vaft technique). Prefetched segments are held back during announced breaks so an ad doesn't flash on screen.
- **Player, Twitch-style:**
  - Tap the video for controls; they fade out on their own. The gear holds **Quality**, **Low latency** and **Video stats**.
  - **Gestures:** double-tap for full screen (in landscape: zoom to fill / fit); pinch to fill or fit; swipe up for full screen; pull the video down to shrink it into the **mini player** (it follows your finger); in landscape, swipe down to leave full screen and left/right to show or hide chat.
  - **Mini player:** keeps playing in the corner above the tab bar while you browse. Tap or drag it up to open, pause or close it with its buttons, or throw it aside to close (closing stops the stream right away).
  - Tap the streamer's picture or name under the video to open their channel (the player shrinks into the mini player; a channel page that's already open is gone back to, not opened twice). The heart follows them.
  - **Lock screen and Control Center:** title, channel and picture, play/pause, and for VODs the progress bar and 10-second skips, while it plays in the background.
  - Tap anywhere outside the message box (the video, chat, the bar under the video) to put the keyboard away; shrinking the player puts it away too.
  - **Landscape:** the video only keeps clear of the Dynamic Island, and chat sits on the side away from it, so chat text runs to the screen edge (toggle with the chat button or a swipe, drag the line between them to resize). The player turns with the phone; the full-screen button holds landscape until you turn the phone.
  - **Rewind live streams:** when the channel records a VOD of the broadcast (and it plays for you), a seek bar runs from the start of the stream to now. Drag back to watch from any point; tap LIVE or drag to the end to return. Channels without that VOD don't get the bar. Touching the bar loads the VOD out of sight and keeps it near your finger, so letting go only has to start it; the VOD stays loaded for a few minutes after you go back to live, and going back to live reuses the stream's playlists (no new token). Going back to live, the VOD keeps playing (picture and sound) until the live stream is playing again, so nothing freezes. While you're back in time, chat shows what was said at that point (from the VOD), and live chat (including what arrived meanwhile) comes back with LIVE. Seeks land on the first keyframe at or after the spot, and the seek bar holds still until they do.
  - **VOD seek previews:** dragging the seek bar shows a thumbnail of where you'll land (Twitch's storyboards), on VODs and live rewinds; the other controls step aside while you drag.
- **VODs:**
  - Start at the beginning, or where you left off: positions are saved on the iPhone and, signed in, to your Twitch account the way Twitch's player does, so the website and apps resume at the same point. Channel video lists show how far you got.
  - **Chat replay** in time with the video.
  - Parts Twitch muted for copyright play (silently) instead of freezing: Twitch lists them under file names that don't exist, and Kestrel corrects them like Twitch's own player.
  - A VOD of a stream that's still live shows "RECORDING". It plays as a finished VOD of what's been recorded so far (the Apple player stalls on open-ended recordings) and loads more as you near the end. If playback ever gets stuck on a broken part, Kestrel skips ahead a few seconds.
  - One layout for both orientations, so rotating, opening chat, the keyboard and the emote picker all animate instead of rebuilding the player.
  - Picture in Picture, AirPlay, background audio, tap LIVE to jump back to the live edge.
- **Starts near the live edge:** through an ad-free server, Twitch's ad announcements don't hold back the newest segment (that's what left streams that started during one a few seconds behind until LIVE was tapped).
- **Low latency:** the [Amazon IVS Player SDK](https://docs.aws.amazon.com/ivs/latest/LowLatencyUserGuide/player-ios.html) (the engine Twitch's own apps use) in Twitch's low-latency mode. It starts with half a second buffered, and when more builds up than needed (it starts on a keyframe, so up to two seconds extra; or after a hiccup) it plays slightly faster (up to 1.2×) for a few seconds until only a small safety margin is left; the margin grows a little if the connection stalls and shrinks again while it's smooth. The playlist server is contacted while the player is still being set up, and Live restarts on the same playlists under a new address (quick). Twitch's master playlist carries its clock (`SERVER-TIME`, `STREAM-TIME`), which the player sets its idea of "now" from, so Kestrel moves those on by the time since it fetched the playlist whenever it serves it (served unchanged after a while, the player reported no latency at all). Through an ad-free server, Twitch hands out playlist and video servers near *that* server (Europe), so Kestrel tries the same playlists on Twitch's server near you and uses it when it accepts them (falling back if it ever refuses or shows an ad; **Twitch servers near me** in Ad blocking turns this off). Falls back to the Apple player (AVPlayer, ~8–12 s behind) if it can't play a stream. Only in builds made with the SDK (the GitHub Actions build downloads it). VODs use the Apple player.
- **Highest quality, or a steady Auto:** the top rendition is picked and kept, unless you pick Auto (then later streams start on Auto too). Auto starts at the quality that last played smoothly, and once a quality stalls or Auto has to drop straight back down from it, Auto stays below it for a while (30 s, doubling each time it fails again, up to 8 min) before trying again, so it settles instead of bouncing. Kestrel asks Twitch for every codec the iPhone decodes in hardware, so channels using Enhanced Broadcasting list their HEVC/AV1 1440p renditions; renditions the low-latency player can't decode appear as "· Apple player". Twitch only offers 1440p to some signed-in viewers in some regions.
  - Through an ad-free server, Kestrel also checks what Twitch itself offers. If that's more (e.g. 1440p the server's anonymous copy doesn't have), it's listed in the quality menu as "· no ad-free server": picking it plays this stream straight from Twitch (Basic ad blocking, so ads are possible). While it does, the qualities the ad-free server has are marked "· ad-free": picking one (or Auto) goes back to it.
- **Sign in with Twitch** (optional) on Twitch's own login page inside the app:
  - **Chat as yourself**, with room-mode notices (slow, followers-only, sub-only); hold a message to reply to its sender. Autocorrect and spell check work in the message box.
  - **Emote picker** (smiley button): every emote you can use in this channel — the channel's sub and follower emotes you have, your other subs, Twitch's, and the channel's 7TV/BTTV/FFZ emotes — with Recent first.
  - **Autocomplete:** type `:` and a few letters for emotes, `@` for people in chat. Emotes show as pictures in the message box once typed (delete the picture to remove the emote).
  - **Following** shows your Twitch follows, live channels first (sorted by viewers) and offline ones with when they were last live.
  - **Follow and unfollow on Twitch** with the heart (under the video and on channel pages). Twitch only accepts follows from its own website, so, like Xtra on Android, Kestrel opens twitch.tv invisibly once in a while to get the website's token. If Twitch still refuses, the channel goes in Kestrel's own Following list instead and you're told. Signed out, the heart only uses Kestrel's list.
- **Chat:** Twitch, 7TV, BTTV and FFZ emotes (animated), badges, and recent messages when you join. New messages glide in frame by frame (busy chats and VOD replays included); only messages whose pictures arrive late are redrawn.
- **Lists:** live channels as compact rows like Twitch's (small picture on the left; streamer, title, category and tags on the right). Each row is one tile that opens the stream (hold it for the channel or category). The system's pull to refresh. Browse switches between Live and Categories with a swipe. Search keeps your recent searches (swipe one away, or Clear) and fetches its results again when you come back to it, so who's live stays current.
- **Go-live alerts** (Settings → Notifications): a notification when a channel you follow (or hearted) goes live; tap it to watch. Kestrel checks every minute while it's open or playing. A sideloaded app has no push server, so once Kestrel is closed iOS decides when it may check in the background (often every 15–30 minutes, less if you rarely open it, never if you swipe it away in the app switcher), and alerts can come late.
- **Liquid Glass look:** the floating glass tab bar (slide a finger along it to switch sections), with glass navigation bars and menus.
- **iPhone Duo:** built with the iOS 27.1 SDK, Kestrel fills both displays and follows along when the phone is opened or closed. On the inner display it's used whichever way it's held: in landscape, chat runs down one side with the video beside it, the stream's info bar under the video and its details (whole title, viewers, uptime, category, tags) in the room below. With the details showing, the info bar is just the channel (avatar, name, follow) so nothing is said twice. The status bar is hidden there, and if a strip still runs down one side, the video takes that side and runs under it (only its controls and text keep clear) while chat takes the other side edge to edge. In portrait, chat sits under the video; while typing, the info bar steps aside and the video shrinks so the message box and some chat stay above the tall keyboard. The gear menu's **Video in the middle** puts the video halfway down its column in landscape (info bar above it, details below). On the outer screen, the video runs under the side strip in portrait and under the camera's side in landscape, landscape chat can be narrower (drag its edge), and **Chat over video** in the gear menu lays chat over a full-width video instead. Full screen gives the video the whole display. Lists show streams as cards in two columns (an even number of columns keeps the fold between them), categories in more columns. Layouts go by the window's size, not the device, so iPad and split screen get the same treatment.
- **Skip 10 seconds:** back and forward buttons beside play/pause in VODs and while rewinding a live broadcast (from live, back jumps into the recording, which runs a little behind), and on the lock screen.
- **Video stats:** a Twitch-style overlay (switches to columns on a small video; ✕ to close it) with player, quality, codecs, resolution, frame rate, bitrate, bandwidth, buffer, latency, catch-up speed and safety margin, Twitch's video server (near you or the ad-free server's), Auto's current limit, dropped frames, ad state and ad-blocking route.

**Starting fresh:** deleting an app on iOS keeps what it saved in the Keychain, so Kestrel now clears its Keychain items (the Twitch login, your proxy password) the first time it runs after a reinstall. **Settings → Reset Kestrel** erases everything it has stored at any time, then closes it so it opens as new.

**Settings → Activity log** shows which ad-free server delivered each stream (and where Twitch thinks you are), ad breaks, player fallbacks, and image hosts that fail to load.

## Install

Download the IPA from the latest GitHub Actions run (**Actions → Build IPA and APK → Artifacts**) and sideload it with your usual tool (SideStore, AltStore, Feather, TrollStore…). Requires iOS 16+.

- **Kestrel-ipa**: the iPhone app (Xcode 27.1, iOS 27.1 SDK).
- **Kestrel-apk**: the Android app (Android 8.0+). Open the APK on the phone to install it; it can be shared with anyone as is. See [android/README.md](android/README.md).

## Build

**GitHub Actions** (no Mac needed): push to your repo. The `Build IPA and APK` workflow makes one build of each app:
- iPhone: on GitHub's Xcode 27 runner with Xcode 27.1, it downloads the Amazon IVS Player SDK (pinned version, SHA-256 checked) and runs `./build.sh` → `Kestrel-ipa`. If the IVS SDK can't be downloaded or linked, it builds without the low-latency player and flags a warning on the run.
- Android: Gradle in `android/` → `Kestrel-apk`.

**Locally** (macOS with Xcode 27.1 or later): run `./build.sh`. For the low-latency player, unpack `https://player.live-video.net/<version>/AmazonIVSPlayer.xcframework.zip` into `vendor/` (or set `IVS_XCFRAMEWORK`).

**Core tests** (playlist parsing, ad handling against a simulated Twitch and ad-free server, the local server, chat parsing): `./Tests/run.sh`. Needs a host Swift toolchain (Linux or macOS).

## Layout

| Path | What |
|---|---|
| `Sources/Core/AdFreeProxy.swift` | The ad-free servers and how they're asked for a stream |
| `Sources/Core/HLS.swift` | Playlist parsing, ad markers |
| `Sources/Core/StreamSession.swift`, `LowLatencySession.swift` | Ad handling for the Apple and low-latency players |
| `Sources/Core/LiveCatchUp.swift` | Keeps the low-latency player close to live (catch-up speed, safety margin) |
| `Sources/Core/SteadyAutoQuality.swift` | Keeps Auto quality from bouncing back up to a quality that just stalled |
| `Sources/Core/LocalHTTPServer.swift` | Localhost server the players load playlists from |
| `Sources/Twitch/` | GraphQL API, sign-in, playback tokens, follows, chat/IRC, third-party emotes |
| `Sources/App/` | SwiftUI app: player screen and controls, players, chat (UIKit list with animated emotes), images |
| `android/` | The Android app (Kotlin, Jetpack Compose, Media3/ExoPlayer) |

## Limitations

- The ad-free servers are run by third parties (PerfProd, Luminous). They see which channel you open, not your Twitch login; if none answers, Kestrel falls back to Basic ad blocking.
- Streams fetched through an ad-free server are requested anonymously, so 1440p that Twitch reserves for signed-in viewers may not be listed there (channels you're subscribed to play straight from Twitch and keep it). When Twitch offers more, the quality menu says so; or switch Ad blocking to Basic to always play straight from Twitch.
- Following on Twitch depends on Twitch's website handing out its token to Kestrel's invisible page; Twitch can change that at any time (then the heart falls back to Kestrel's own list).
- The Amazon IVS Player SDK isn't open source; it's distributed by AWS under its own terms and isn't included in this repository.

## Credits

Ad-free servers: [TTV LOL PRO](https://github.com/younesaassila/ttv-lol-pro) v1 list (PerfProd, [luminous-ttv](https://github.com/AlyoshaVasilieva/luminous-ttv)). Ad markers and the backup-stream approach: [TwitchAdSolutions](https://github.com/ryanbr/TwitchAdSolutions) (MIT) and [streamlink](https://github.com/streamlink/streamlink)'s Twitch plugin (BSD-2). GraphQL query shapes follow [Xtra](https://github.com/crackededed/Xtra). Not affiliated with Twitch.
