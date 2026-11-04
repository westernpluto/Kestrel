# Kestrel for Android

The same ad-free, low-latency Twitch client as the iPhone app, for phones running Android 8.0 or later. It's a native Kotlin app (Jetpack Compose, Media3/ExoPlayer) that shares the iPhone app's approach: the same ad-free servers, ad handling, chat and features.

## Install and share

1. Open the latest run under **Actions → Build IPA and APK** and download the **Kestrel-apk** artifact (GitHub delivers it as a zip; `Kestrel.apk` is inside).
2. Open `Kestrel.apk` on the phone. Android asks once to allow installing apps from that source (the browser or Files app); allow it, then tap **Install**.

Anyone can install that same `Kestrel.apk`: send it to them in any messenger or share it from Google Drive. Newer builds install over older ones and keep the login and settings, because every build is signed with the same key (see "Signing" below).

## What's the same as on iPhone

- **Ad blocking:** the TTV LOL PRO v1 ad-free servers (Automatic, or a server you pick), your own HTTP proxy, or Basic. Signed in with a sub to the channel (or Turbo), Kestrel plays straight from Twitch. Stitched-in ads are swapped for an ad-free copy of the stream (other player types), or muted and covered as a last resort. **Settings → Activity log** shows what happened.
- **Low latency:** Twitch's low-latency playlist, with the segment Twitch is still producing played as it arrives (ExoPlayer keeps about 3.5 s behind live and adjusts gently).
- **Highest quality, always**, including HEVC/AV1 1440p renditions when the phone decodes them in hardware; a quality only Twitch itself offers (not the ad-free server) is listed as "· no ad-free server".
- **Player:** tap for controls, double-tap for full screen (in landscape: fill/fit), pinch to fill or fit, swipe up for full screen, pull the video down to shrink it into the mini player above the tab bar (drag it up to open, throw it aside to close). In landscape, chat sits beside the video (drag the divider to resize, swipe the video sideways to show or hide it).
- **Rewind live streams** through the broadcast's VOD while it's recorded, with seek previews and chat from that point of the stream.
- **VODs:** resume where you left off (synced with your Twitch account when signed in), chat replay, muted parts that play instead of freezing, recordings that keep growing.
- **Chat:** Twitch, 7TV, BTTV and FFZ emotes (animated), badges, recent messages, sending as yourself, the emote picker, `:emote` and `@name` autocomplete, hold a message to copy it or reply.
- **Sign in with Twitch**, follow/unfollow on Twitch, your follows in Following. Sign-in problems are written to **Settings → Activity log**.
- **Go-live alerts**, background audio with the media notification and lock screen controls, picture in picture, **Settings → Reset Kestrel**.

## What's different

- **Signing in** works with a code by default, the way TV apps sign in: Kestrel shows a code, you enter it at twitch.tv/activate in any browser where you're signed in to Twitch (the phone's own, or another device's) and approve it, and Kestrel signs in by itself (Twitch lists it as its TV app). Twitch's login page inside the app, and pasting the auth-token, are the other two options on the sign-in screen. A code sign-in renews itself before it runs out.
- **Background checks for go-live alerts** run about every 15 minutes (Android's minimum for background work), every minute while the app is open or playing. Battery savers on some phones can delay them; exclude Kestrel from battery optimization if alerts come late.
- **Picture in picture** starts when you leave the app while a stream plays (Settings → Picture in picture), or from the player's PiP button.
- **Rewinding** switches the one video player between the live stream and the VOD (the last picture stays up meanwhile, so there's no black flash, but each switch takes a moment to buffer). The iPhone app keeps both loaded.
- **The message box** shows emotes as their names while you type; they show as pictures once sent.
- **Uninstalling removes everything** (cloud backup is turned off for Kestrel), so a reinstall starts signed out. Reset Kestrel uses Android's own "clear storage".

## Build

GitHub Actions builds the APK next to the IPA on every push (the `build-android` job: JDK 17, Gradle 8.9, `gradle assembleRelease` in this folder).

Locally: install Android Studio (or the command-line SDK with platform 34 and JDK 17), then in this folder run `gradle assembleRelease` (or open the folder in Android Studio). The APK lands in `app/build/outputs/apk/release/`.

## Signing

Official builds are signed with a release key kept out of the repository: GitHub Actions takes it from the repository's `KESTREL_KEYSTORE_BASE64` (the keystore, base64) and `KESTREL_KEYSTORE_PASSWORD` secrets, so every build installs as an update over the last and nobody else can sign one that would. A build without them (locally, or in a fork) is signed with the debug key: it installs, but not over an official build. To sign with your own key, set `KESTREL_KEYSTORE` (the keystore's path), `KESTREL_KEYSTORE_PASSWORD` and optionally `KESTREL_KEY_ALIAS` (default `kestrel`) when building.

## Layout

| Path | What |
|---|---|
| `app/src/main/java/app/kestrel/core/` | Twitch API, playlists (HLS parsing, the live timeline, ad handling), ad-free servers, codecs |
| `app/src/main/java/app/kestrel/chat/` | IRC chat, messages, third-party emotes, VOD chat replay |
| `app/src/main/java/app/kestrel/data/` | Settings, the Twitch login, follows, watch history, go-live alerts, integrity token, reset |
| `app/src/main/java/app/kestrel/player/` | The player (ExoPlayer), playlists served to it, background playback service |
| `app/src/main/java/app/kestrel/ui/` | Compose screens: lists, channel pages, search, settings, player and chat |
