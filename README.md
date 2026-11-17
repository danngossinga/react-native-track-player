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
  not progress). On iOS the stage that loads the playlists (before the asset is
  playable) has no progress signal, so only `prepareTimeoutMs` ends it; after
  it, progress is buffered media and the item's transferred bytes, which
  AVFoundation does not split between playlists and media. On Android a
  crossfade load therefore gives up after `stallTimeoutMs` (10 s by default)
  with no progress, counted once its playlists are in and its first segment has
  been requested, and stops the player's background retries. Emulator check at
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
  track took over) and `standard_seek_unavailable` (no active track, or it failed
  to load); the crossfade backend uses `crossfade_seek_timeout`,
  `crossfade_prepare_timeout` or `crossfade_engine_error` (the track had to load
  again and failed) and `cancelled`. iOS sent all of them as `seek_failed`
  before; it still does for `standard_seek_invalid_position` (a position that is
  not a finite number), which only iOS checks.
- `skip`, `skipToNext`, `skipToPrevious` and `load` resolve once their track
  loaded and is the active one (`getActiveTrackIndex()` returns it), on both
  backends and both platforms, paused or playing; `initialPosition` is applied
  after that load. When the track fails to load they reject and the previous
  track stays active: `crossfade_prepare_timeout` (a give-up),
  `crossfade_engine_error` (a player error) or `cancelled` (a newer skip, load,
  seek, stop or queue change took over; on the standard backend a pause does not
  end the load, so it does not cancel the command). The rejection is the report:
  no `PlaybackError` event for it. A load no command waits for (a natural
  advance, a play or retry after a failure) reports its failure with a
  `PlaybackError` event (`code`, `message`). iOS now rejects crossfade loads that
  give up or are cancelled with these codes too (before: `skip_failed`,
  `playback_backend_load_failed`), as Android.
- A track becomes the active one once it loaded, on both backends and both
  platforms (iOS crossfade's rule, the chosen alignment): `PlaybackActiveTrackChanged`
  (and the deprecated `PlaybackTrackChanged`) comes then, never for a track that
  failed to load (a give-up or a player error). While a track loads, and after its
  load failed, the previous track is the active one (none when there was none);
  the next play loads it again or, when there was none, retries the track that
  failed. The standard backend reports a new queue's first track at once (it is
  selected when the queue is set). After a failed load the lock screen and the
  notification show the active track again. A failed seek keeps its target as the
  position on both backends and platforms.
- On the standard backend, while a track loads (and after its load failed) every
  reader agrees with the active track: `getProgress`/`useProgress` and the
  progress events give the active track's last position, duration and buffered
  position (not the loading track's), and the lock screen (iOS) and the
  notification (Android) keep showing the active track; they switch when the new
  track is reported. On iOS the lock screen also shows the active track's last
  position, not moving; Android's media session still reads its position from the
  player (the loading track's) while the notification shows the active track's
  title and artwork.
- The total limits, safety caps behind the stall timeout, with the same rules:
  `prepareTimeoutMs` (crossfade load and every crossfade seek; on iOS the stage
  before the asset is playable has no progress signal, so only this limit ends
  it; an iOS crossfade seek, which had no limit before, now fails on a stall or
  at this limit and the player then reports an error state), `playStartTimeoutMs` (crossfade play start, iOS and Android),
  `standardReadyTimeoutMs` (standard backend readiness) and
  `standardSeekTimeoutMs` (standard seek, iOS and Android; on iOS, before the seek
  is issued only this limit applies, then the buffered position is its only
  progress signal), each
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
