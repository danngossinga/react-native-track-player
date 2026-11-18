<img src="https:/rntp.dev/img/optimized-logo.svg" width="300" />

[![downloads](https://img.shields.io/npm/dw/react-native-track-player.svg)](https://www.npmjs.com/package/react-native-track-player)
[![npm](https://img.shields.io/npm/v/react-native-track-player.svg)](https://www.npmjs.com/package/react-native-track-player)
[![discord](https://img.shields.io/discord/567636850513018880.svg)](https://discordapp.com/invite/ya2XDCR)
[![Commitizen friendly](https://img.shields.io/badge/commitizen-friendly-brightgreen.svg)](http://commitizen.github.io/cz-cli/)

----

A fully-fledged audio module created for music apps. Provides audio playback, external media controls, background mode and more!

<div align="left" valign="middle">
<a href="https://runblaze.dev">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://www.runblaze.dev/logo_dark.png">
   <img align="right" src="https://www.runblaze.dev/logo_light.png" height="102px"/>
 </picture>
</a>

<br style="display: none;"/>

_[Blaze](https://runblaze.dev) sponsors RNTP by providing super fast Apple Silicon based macOS Github Action Runners. Use the discount code `RNTP50` at checkout to get 50% off your first year._

</div>

## Overview

- [Documentation](https://rntp.dev)
  * [Installation](https://rntp.dev/docs/basics/installation/)
  * [Getting Started](https://rntp.dev/docs/basics/getting-started/)
  * [API Docs](https://rntp.dev/docs/api/events)
  * [Platform Support](https://rntp.dev/docs/basics/platform-support)
  * [Background Mode](https://rntp.dev/docs/basics/background-mode)
  * [Build Preferences](https://rntp.dev/docs/basics/build-preferences)
  * [v2 Migration Guide](https://rntp.dev/docs/v2-migration)
- [Sponsors](#sponsors)
- [Features](#features)
- [Why another music module?](#why-another-music-module)
- [Example Setup](#example-setup)
- [Core Team ✨](#core-team-)
- [Special Thanks ✨](#special-thanks-)
- [I Have A Bug/Feature Request](#contributing)
- [Community](#Community)

Not sure where to start?

1. Try [Getting Started](https://rntp.dev/docs/basics/getting-started).
2. Peruse the [API Docs](https://rntp.dev/docs/api/events).
3. Run the [Example Project](/example).

## BFace PingPong Crossfade Fork

This checkout is an internally maintained `react-native-track-player` fork for
PingPong crossfade on iOS and Android. It keeps the upstream package name so
React Native autolinking and existing app imports continue to resolve as
`react-native-track-player`.

Internal version: `4.1.2-bface-pingpong.0`

Local release tag: `v4.1.2-bface-pingpong.0`

Added fork surface:

- `setupPlayer({ crossfade: true })` enables the fork crossfade path.
- `stallTimeoutMs` (`setupPlayer` and `updateOptions`, default 10000): every wait
  for a track (crossfade load, seek and play start, standard backend readiness and
  seek) fails when it makes no progress (no new media downloaded or buffered) for
  this long. A slow load that keeps progressing goes on, up to the wait's own total
  limit below. On Android the players' HTTP connect and read timeouts
  follow it too, from the next request on every track, instead of ExoPlayer's
  fixed 8 s (both the crossfade and the standard player). A new value applies to the next wait at once. Left out, the current
  value is kept. Other options left out of an `updateOptions` call (capabilities,
  progress interval…) are reset, so pass it together with your usual options.
  Progress on Android is media data; an HLS track's playlists and keys count too
  until its first segment is asked for (a slow proxy answering the playlists
  does not fail a healthy track), and not after it (the playlists the player
  reloads when it falls back to another rendition after a failed segment are
  not progress). On iOS a load has two stages, the same on the crossfade and
  the standard backend: until the asset is playable (an HLS track's playlists,
  a file's first requests) the player has no item and nothing shows progress,
  so only `prepareTimeoutMs` ends that stage (a playlist slower than
  `stallTimeoutMs` does not fail the track, as on Android, where its bytes are
  progress); from the item's creation the no-progress countdown starts again,
  and progress on the standard backend, for a load and for a seek once
  issued, is new buffered time (time a buffer that empties and fills again
  does not count twice) and the media bytes of the item's access log
  (AVFoundation never counts playlists there), each wait reading its own, as
  crossfade's waits. After a failed request or a rendition switch (a new
  error-log entry, or an access-log event that is neither the first one nor
  that of a seek the backend issued and that has not completed yet), those
  bytes stop counting until new time is buffered: the bytes posted with a
  switch (the failed transfers of the rendition left, the new rendition's
  segments downloaded again) are not progress (before, every access-log byte
  and any growth of the buffered position counted, so each switch restarted
  the countdown; a standard seek read only the buffered position, the end of
  the last loaded range). Android counts every media byte, so there bytes
  downloaded again at a switch count; iOS is stricter on that point. Android's
  standard seek reads ExoPlayer's buffered position, which grows as media
  arrives and counts a refill after a drop. The
  iOS standard backend reads the item's access log from SwiftAudioEx's AVPlayer
  item, which SwiftAudioEx 1.1.0 keeps private (`AudioPlayer.wrapper` →
  `AVPlayerWrapper.avPlayer`): it is read by reflection (`standardPlayerItem`),
  an owner decision (2026-11-17) that holds only with the podspec pinned to
  exactly SwiftAudioEx 1.1.0 (`s.dependency "SwiftAudioEx", "1.1.0"`; the iOS
  contract script fails on another pin). With another layout the load binds its
  item from AVFoundation's first access-log notification instead. Before changing
  the pin, run `scripts/verify-swiftaudioex-layout.sh`: it builds the real
  SwiftAudioEx sources (from the CocoaPods cache, or `SWIFTAUDIOEX_SOURCES`) with
  `PlaybackBackend.swift` for Mac Catalyst and checks that `standardPlayerItem`
  reads a real `QueuedAudioPlayer`'s item (without the sources it prints SKIPPED;
  CI runs only the XCTest on a fake of that layout, as the test target cannot
  build SwiftAudioEx).
  (Before, the iOS standard backend also applied `stallTimeoutMs` from the
  start of the load, so a playlist slower than it failed the track.) What
  AVFoundation shows while an HLS segment arrives was measured on the iOS 26.5
  simulator with a real AVPlayer and a local HLS server, packed AAC and
  AES-128 CMAF/fMP4 (2026-11-17, the iOS rendition-fallback measurements of
  `fix/device-proof-stalls`, summarised in its README at 1c78b91): on loads,
  the loaded time ranges grow while a segment arrives, partial bytes
  included, and a CMAF segment's access-log bytes grow in flight too (a
  packed-AAC segment's bytes are posted once it completes), so a slow segment
  of a load is progress. Remaining gap: a seek into an HLS CMAF (fMP4) segment
  shows no progress on iOS until that segment is buffered (in the measured
  run neither its bytes nor the loaded ranges moved while it arrived), while
  Android counts media bytes in flight: a CMAF segment slower than
  `stallTimeoutMs` fails a seek on iOS (both backends) though its bytes keep
  coming. Keep `stallTimeoutMs` above the longest expected download time of
  one segment. (An earlier measurement with AVFoundation on macOS, 4 s TS
  segments sent over 8 s each, saw no change of any signal until a segment's
  last byte; the simulator runs above are the iOS behaviour.) On Android the
  no-progress countdown of a crossfade load runs from the start of the load:
  until its first segment is requested, playlist and key bytes reset it; after
  that only media bytes (and buffered media) do. When it reaches
  `stallTimeoutMs` (10 s by default) the load gives up and stops the player's
  background retries. Emulator check at
  commit 1cbac20 (before playlists counted until the first segment): a load
  whose segment never came gave up 10.0–10.4 s after it started; a longer wait
  seen by the app came from its own calls.
  A crossfade load or seek that gives up stops loading at once (Android stops the
  player, iOS removes the item: no request is retried in the background) and
  leaves the player in an error state; the next play loads the track again. When
  the track that follows an ended one fails to load (no command waits for it),
  the crossfade backend reports it with a `PlaybackError` event (`code`, for
  example `crossfade_prepare_timeout`, and `message`) on both platforms.
  The standard backend follows the same rule on both platforms: a load (a load,
  a skip, a natural advance, a retry) whose media makes no progress for
  `stallTimeoutMs`, or exceeds `prepareTimeoutMs`, stops loading and leaves the
  player in an error state with the same `crossfade_prepare_timeout` code; a
  stalled standard seek stops loading and leaves the player in error (its promise
  rejects with `standard_seek_timeout`).
- `seekTo` and `seekBy` reject with codes that depend on the backend (the same
  codes on Android and iOS): the standard backend uses `standard_seek_timeout`
  (no progress for `stallTimeoutMs`, or over `standardSeekTimeoutMs`),
  `standard_seek_cancelled` (a newer seek, a skip, pause, stop, load or another
  track took over) and `standard_seek_unavailable` (the track it acts on failed
  to load, a player error); the crossfade backend uses `crossfade_seek_timeout`,
  `crossfade_prepare_timeout` or `crossfade_engine_error` (the track had to load
  again and failed) and `cancelled`. iOS sent all of them as `seek_failed`
  before; it still does for `standard_seek_invalid_position` (a position that is
  not a finite number), which only iOS checks.
- A standard seek in a track the player cannot seek in (a stream with no length
  or index, such as a raw ADTS radio stream: ExoPlayer's window is not seekable,
  AVPlayer's item has no seekable range) resolves where the player lands, on both
  platforms (before: Android waited for the target and failed with
  `standard_seek_timeout` after `stallTimeoutMs`, leaving the player in error;
  iOS never issued it, as such a stream has no duration, and rejected it at
  `standardSeekTimeoutMs`). Where it lands differs: ExoPlayer goes back to the
  start of the track; iOS issues the seek once the item is ready, and AVPlayer
  seeks within the data it has loaded or stays where it is (measured with
  AVFoundation on macOS, not on an iOS device).
- `skip`, `skipToNext`, `skipToPrevious` and `load` resolve once their track
  loaded and is the active one (`getActiveTrackIndex()` returns it), on both
  backends and both platforms, paused or playing; `initialPosition` is applied
  after that load. When the track fails to load they reject and the previous
  track stays active: `crossfade_prepare_timeout` (a give-up),
  `crossfade_engine_error` (a player error) or `cancelled` (a newer skip, load,
  seek, pause, stop or queue change took over). A command rejected `cancelled` by
  a seek, pause or stop does not take effect, on both backends and platforms: its
  track is never reported, the player goes back to the active track, paused
  (crossfade's cancelled operation), and the seek acts on that track (before: the
  standard backend paused or sought the loading track, which then became active;
  a pause did not cancel the command). With no active track (the first track's
  load failed), the cancel stops the loading track and leaves no active track
  (crossfade's active index -1): that track is never reported, a seek then
  resolves and does nothing (before: it rejected with `standard_seek_unavailable`),
  adding, moving or removing tracks or setting a new queue loads nothing and keeps
  no active track (before: the player loaded its item again, or the new queue's
  first track, and reported ready with no active track), and the next play (skip,
  next, load, retry) starts the first track, reported once it loaded, never at
  once, as crossfade's play with no active track (before: the cancelled track went
  on loading and became active; the play's track was reported at once, then none
  again when it failed). A backend switch that restores no active track is the
  same. Nothing of the cancelled track loads after that,
  not even a playlist: Android's standard backend releases its source (ExoPlayer
  would keep it prepared while it is in the queue, and an HLS source would fetch
  its primary media playlist); on iOS SwiftAudioEx cancels the asset's loading.
  `seekBy` (and the remote jump buttons, which call it) is relative to the
  position the app reads: the active track's while another track loads (before:
  the loading track's). The rejection is the report:
  no `PlaybackError` event for it. A load no command waits for (a natural
  advance, a play or retry after a failure) reports its failure with a
  `PlaybackError` event (`code`, `message`), after the `PlaybackState` error event
  (both backends and platforms, a give-up and a player error alike; before, the
  standard backend sent the `PlaybackError` first: on Android for both, on iOS
  for a player error, whose state SwiftAudioEx emits later from another queue).
  One case keeps the iOS error alone: SwiftAudioEx's failed-to-play-to-end
  failure leaves its state unchanged, so no error state precedes it (Android's
  player is in error after every player error). iOS now rejects crossfade loads that
  give up or are cancelled with these codes too (before: `skip_failed`,
  `playback_backend_load_failed`), as Android.
- A track becomes the active one once it loaded, on both backends and both
  platforms (iOS crossfade's rule, the chosen alignment): `PlaybackActiveTrackChanged`
  (and the deprecated `PlaybackTrackChanged`) comes then, never for a track that
  failed to load (a give-up or a player error). While a track loads, and after its
  load failed, the previous track is the active one (none when there was none);
  the next play loads it again or, when there was none, retries the track that
  failed. A seek or stop acts on the active track, the one the app reads
  (`getActiveTrack` and its position), as crossfade's (owner decision,
  2026-11-17): after a failed load the player goes back to the active track; the
  seek acts there and then plays when playback was requested before the failure,
  as crossfade's seek after a failed skip (a pause after the failure ends that
  request), a stop stops there; on the standard backend while another track loads
  (a natural advance, which the seek or stop cancels, as crossfade's cancelled
  operation) it goes back paused, and the next play plays it (before: the seek
  acted on the track that failed and, when it failed too, the next play loaded
  the previous track; then: the seek after a failed load left it paused). With no
  active track after the first load failed, a seek retries the track that failed
  (crossfade's seek does nothing there); when it fails again, the next play
  retries that track. A skip or next to the track that failed loads it
  again. The standard backend reports a new queue's first track at once (it is
  selected when the queue is set). After a failed load the lock screen and the
  notification show the active track again. A failed seek keeps its target as the
  position on both backends and platforms.
- On the standard backend, while a track loads (and after its load failed) every
  reader agrees with the active track: `getProgress`/`useProgress` and the
  progress events give the active track's last position, duration and buffered
  position (not the loading track's), and the lock screen (iOS) and the
  notification (Android) keep showing the active track; they switch when the new
  track is reported. The lock screen (iOS) and the media session and notification
  (Android) also show the active track's last position, duration and buffered
  position, not playing (before, Android's media session and notification read the
  loading track's position and duration from the player). Android keeps the
  player's play-when-ready there (the notification's ongoing flag keeps the
  foreground service), so its session shows buffering at that position, speed 0,
  where iOS shows the lock screen paused (rate 0). Android's media session also
  has the active track as its current item (its active queue item, next and
  previous; before: the loading track) and, after a give-up, shows the error
  state the app reads (before: none).
- The total limits, safety caps behind the stall timeout, with the same rules:
  `prepareTimeoutMs` (crossfade load and every crossfade seek, and the standard
  backend's load; on iOS the stage before the asset is playable has no progress
  signal on either backend, so only this limit ends it, and `stallTimeoutMs`
  applies from the item's creation; an iOS crossfade seek, which had no limit before, now fails on a stall or
  at this limit and the player then reports an error state), `playStartTimeoutMs` (crossfade play start, iOS and Android),
  `standardReadyTimeoutMs` (standard backend readiness) and
  `standardSeekTimeoutMs` (standard seek, iOS and Android, set apart from
  `prepareTimeoutMs`: a seek owns its track's loading, which the load limit does
  not end meanwhile; on iOS, before the seek is issued only this limit applies,
  then the buffered position is its only progress signal: a seek on a track whose
  playlists never answer gives up at `stallTimeoutMs` on Android and at this limit
  on iOS, then on both it stops loading, fails the track again and leaves the
  player in error, and the next play loads the active track, or retries that
  track when none is active), each
  60000 by default. On iOS, a backend switch waits at most the load limit plus
  the play-start limit plus 5 s (at least 10 s); on Android it does not block a
  thread and is bounded by the load and play-start waits themselves. The play
  that resumes after an interruption is not awaited on either platform.
- A play the system refuses (Android audio focus denied; iOS audio session not
  activated) does not start, on iOS and Android and both backends: the player
  stays paused, `play()` / `setPlayWhenReady(true)` reject with
  `audio_focus_refused` (`PlaybackErrorCode.AudioFocusRefused`), and a play no
  one awaits (a remote control, an interruption's resume) emits it as a
  `PlaybackError`. A load, skip, seek or retry that would start the audio
  (`playWhenReady` on, nothing playing) is a play too: refused, it runs paused
  and rejects with that code. Nothing retries by itself; the app shows its own
  message.
- `incomingStallGraceMs` (crossfade, `setupPlayer` and `updateOptions`, default
  2000): how long a crossfade waits for the incoming track to start moving before
  it falls back to playing that track alone (`incoming_stalled`).
- `initialBitrateEstimateBps` (Android, both backends, `setupPlayer` and
  `updateOptions`, default 96000): the bandwidth each track starts from before the
  player has measured the network. An adaptive stream starts at the highest
  rendition fitting about 70 % of it, or the lowest when none fits, and climbs as
  the player measures (HLS audio renditions adapt even though the master playlist
  gives no channel count or sample rate). It is a start-of-track estimate: a new value is used at
  the next track start; the playing track is not reset mid-track (its rendition
  follows the measured bandwidth).
- `crossFadePrepare(previous?, seekTo?)` prepares the alternate native player.
- `crossFade(fadeDuration?, fadeInterval?, fadeToVolume?, waitUntil?)` performs
  the two-player overlap transition.
- `playback-crossfade-state` reports sanitized native crossfade state.

Current validated scope:

- iOS physical manual GO.
- Android physical manual GO.
- `example-itunes-lites` integration GO through the local file dependency.

Current limits:

- The fork is maintained internally; upstream RNTP does not own this surface.
- New Architecture compatibility audit is pending.
- Long background-duration and edge-case playback coverage is pending.

Consumer apps should pin both the local tag and the exact commit SHA in their
own docs or dependency lock strategy. Until this fork is published to an
internal registry or a remote Git repository, local apps should consume it with
a checked-out `file:` dependency and verify:

```bash
git -C <path-to-react-native-track-player-ios-crossfade> rev-parse HEAD
git -C <path-to-react-native-track-player-ios-crossfade> rev-parse v4.1.2-bface-pingpong.0
```

## Commerical Usage

**Are you using RNTP for a personal project?** Great! Sponsor us if you're able but otherwise you can support us by reporting any bugs you find, sending us screenshots of your projects and starring us on Github 🌟

**Are you using RNTP at your organisation and/or making money from it?** Awesome! We rely on your support to keep RNTP developed and maintained under the Apache-2.0 license. You can do that through [Github Sponsors](https://github.com/sponsors/doublesymmetry).

## Features

* **Lightweight** - Optimized to use the least amount of resources according to your needs
* **Feels native** - As everything is built together, it follows the same design principles as real music apps do
* **Multi-platform** - Supports Android, iOS and Web
* **Media Controls support** - Provides events for controlling the app from a Bluetooth device, the lock screen, a notification, a smartwatch or even a car
* **Local or network, files or streams** - It doesn't matter where the media belongs, we've got you covered
* **Adaptive bitrate streaming support** - Support for DASH, HLS or SmoothStreaming
* **Caching support** - Cache media files to play them again without an internet connection
* **Background support** - Keep playing audio even after the app is in background
* **Fully Customizable** - Even the notification icons are customizable!
* **Supports React Hooks 🎣** - Includes React Hooks for common use-cases so you don't have to write them

## Why another music module?
After trying to team up modules like `react-native-sound`, `react-native-music-controls` and `react-native-google-cast`, I've noticed that their structure and the way they should be tied together can cause a lot of problems (mainly on Android). Those can heavily affect the app stability and user experience.

All audio modules (like `react-native-sound`) don't play in a separated service on Android, which should **only** be used for simple audio tracks in the foreground (such as sound effects, voice messages, etc.)

`react-native-music-controls` is meant for apps using those audio modules, but it has a few problems: the audio isn't tied directly to the controls. It can be pretty useful for casting (such as Chromecast).

`react-native-google-cast` works pretty well and also supports custom receivers, but it has fewer player controls, it's harder to integrate and still uses the Cast SDK v2.

## Example Setup

First please take a look at the [Getting Started](https://rntp.dev/docs/basics/getting-started/) guide, but a basic example of how to play a track:

```javascript
import TrackPlayer from 'react-native-track-player';

const start = async () => {
    // Set up the player
    await TrackPlayer.setupPlayer();

    // Add a track to the queue
    await TrackPlayer.add({
        id: 'trackId',
        url: require('track.mp3'),
        title: 'Track Title',
        artist: 'Track Artist',
        artwork: require('track.png')
    });

    // Start playing it
    await TrackPlayer.play();
};
start();
```

## Core Team ✨

<table>
  <tr>
    <td align="center"><a href="https://github.com/dcvz"><img src="https://avatars.githubusercontent.com/u/2475932?v=4" width="100px;" alt=""/><br /><sub><b>David Chavez</b></sub></a><br /></td>
  </tr>
</table>

## External Core Contributors ✨

<table>
  <tr>
    <td align="center"><a href="https://github.com/jspizziri"><img src="https://avatars.githubusercontent.com/u/1452066?v=4" width="100px;" alt=""/><br /><sub><b>Jacob Spizziri</b></sub></a><br /></td>
    <td align="center"><a href="https://github.com/puckey"><img src="https://avatars.githubusercontent.com/u/271885?v=4" width="100px;" alt=""/><br /><sub><b>Jonathan Puckey</b></sub></a><br /></td>
  </tr>
</table>

## Special Thanks ✨

<table>
  <tr>
    <td align="center"><a href="https://github.com/Guichaguri"><img src="https://avatars.githubusercontent.com/u/1813032?v=4" width="100px;" alt=""/><br /><sub><b>Guilherme Chaguri</b></sub></a><br /></td>
    <td align="center"><a href="https://github.com/curiousdustin"><img src="https://avatars.githubusercontent.com/u/1706540?v=4" width="100px;" alt=""/><br /><sub><b>Dustin Bahr</b></sub></a><br /></td>
  </tr>
</table>

## Contributing

You want this package to be awesome and we want to deliver on that. As you know
already you can just [File A Ticket](#file-a-ticket), but thats not actually the
best way for you to get what you need (read on to see why). The best way is for
you to [Be A Champion](#be-a-champion) and [dive into the code](#where-do-you-start).

#### File A Ticket

The reality is that filing a ticket isn't always enough. **This is probably only
going to work if your issue aligns with both the interests _and_ the resources available** to the core team. Here are the things that align with our _interests_
in order of priority.

1. Fixing **_widespread, common, and critical Bugs_**.
2. Fixing **_uncommon but necessary Bugs_**.
3. Introducing new  **_Features that have broad value_**.

Now keep in mind available resources. Long story short, the thing you care about
needs to be cared about by either a lot of other people, or by us.

**BUT!** There's another and, arguably even **_better way_** that helps you get what
you need faster: [Be A Champion](#be-a-champion).

#### Be A Champion

Being a _champion_ makes it easy for us to help you. Which is what we all want!
So how can you be a champion? [Sponsor the Project](https://github.com/sponsors/DoubleSymmetry) or _be willing to write some code_.

**If _you're willing_** to write some code **_we're willing_** to:

- Open a design discussion, give feedback, and approve something that works.
- Provide guidance in the implementation journey.

So, in a nutshell, let us know you're willing to do the work and ask for a little
guidance, and watch the things you care about get done faster than anyone else.
The best help will be given to those who are willing to help themselves.

###### You don't have experience you say? It's OK!

You may be thinking that you can't help because you know nothing about native
iOS or Android or maybe even React code. But we're willing to help guide you.

If you're up for that task then we can help you understand native code and how
React Native works.

The only way you go from _not-knowing_ to _knowing_ is by learning. Learning isn't
something you should be ashamed of nor is it something you should be scared of.

#### Where Do You Start?

Our goal is to make it as easy as possible for you to make changes to the library.
All the documentation on how to work on the library and it's dependencies is
[located in this Guide](./example/README.md)

## Release

Program 008 freezes every release path while the hardening program is in
progress. Versioning, Git/tag pushes, npm publication, and the nightly workflow
all run `yarn release:guard` first and stop with
`RELEASE_BLOCKED program=008 status=frozen`. Build and pack workflows remain
available for candidate validation. Unfreezing requires a separate, explicitly
authorized change after all listed gates, global review, and security
prerequisites are satisfied.

The standard release command for this project is [`yarn version`](https://classic.yarnpkg.com/lang/en/docs/cli/version/).

```
yarn version [--major | --minor | --patch | --new-version <version>]
```

Ex.

```
yarn version --new-version 1.2.17
yarn version --patch // 1.2.17 -> 1.2.18
yarn version --minor // 1.2.18 -> 1.3.0
yarn version --major // 2.0.0
```

This command will:

1. Generate/update the Changelog
2. Bump the package version
3. Tag & pushing the commit
4. Build & publish the package


## Community

You can find us as part of the [React Native Track Player](https://discordapp.com/invite/ya2XDCR):

- `#introduce-yourself` - Come greet the newest members of this group!
- `#troubleshooting-forum` - Ask members of the community to trouble shoot issues with your app and make recommendations.
- `#show-and-tell` - Tell the community about the app you made with this project!
- `#news-and-releases` - Stay updated about the latest releases and dev efforts on the project.
