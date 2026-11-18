# Player

## `setupPlayer(options)`

Accepts a [`PlayerOptions`](../objects/player-options.md) object.

## `updateOptions(options)`

Accepts a [`UpdateOptions`](../objects/update-options.md) object. Updates
the configuration for the components.


⚠️ These parameters are different than the ones set using `setupPlayer()`.
Parameters other than those listed below will not be applied.

## `play()`

Plays or resumes the current track.

## `pause()`

Pauses the current track. A skip or load still waiting for its track rejects `cancelled` and does
not take effect: the active track stays (both backends). After a load or seek that gave up, the
player stays in its error state (standard backend, Android and iOS).

## `stop()`

Stops playback. Behavior is the same as `TrackPlayer.pause()` where
`playWhenReady` becomes `false`, but instead of just pausing playback, the item
is unloaded.

This function causes any further loading / buffering to stop. A skip or load still waiting for
its track rejects `cancelled` and does not take effect. After a load or seek that gave up, the
player leaves its error state for the stopped state, with a `PlaybackState` event (standard
backend, Android and iOS).

## `retry()`

Retries the current track when it stopped playing due to a playback error.

## `seekBy(offset)`

Seeks by a relative time offset in the current track. It resolves and rejects as
[`seekTo`](#seektoseconds).

| Param   | Type     | Description             |
| ------- | -------- | ----------------------- |
| offset | `number` | The offset in seconds |

**Returns:** `Promise<void>`

## `seekTo(seconds)`

Seeks to a specified time position in the current track.

The promise resolves once the player is at that position. It rejects with a code that depends
on the backend, the same on Android and iOS:

| Backend | Code | When |
| ------- | ---- | ---- |
| standard | `standard_seek_timeout` | no progress for `stallTimeoutMs`, or over `standardSeekTimeoutMs`; the player stops loading and is in an error state |
| standard | `standard_seek_cancelled` | a newer seek, a skip, pause, stop, load or another track took over |
| standard | `standard_seek_unavailable` | the queue is empty (no track to seek in), or the track it acts on failed to load (a player error) |
| crossfade | `crossfade_seek_timeout` | the seek made no progress, or went over its limit |
| crossfade | `crossfade_prepare_timeout`, `crossfade_engine_error` | the track had to load again and failed |
| crossfade | `cancelled` | a newer command took over |

iOS alone rejects a position that is not a finite number, with `seek_failed`.

A seek during a skip or load that still waits for its track cancels it (`cancelled`) and acts on
the active track, paused (a cancelled operation, as crossfade's). A seek (and a `stop`) acts on
the active track, the one `getActiveTrack()` and the progress report, as crossfade's (owner
decision, 2026-11-17): after a failed load the player goes back to the active track, the seek
acts there and then plays when playback was requested before the failure, as crossfade's seek
after a failed skip. After a failed load the play request stays (`getPlayWhenReady()` and its
event read `true`) until a pause, stop or clear, an empty new queue or the removal of the active
track, as crossfade's; on Android the media session and the notification read it too. On the
standard backend the
player waits paused until the seek is done, then plays, and the state reads `loading` meanwhile
(crossfade's seek state); several seeks in a row (a scrubber drag) keep that request and the
player plays once the latest one is done; the same on the track the player is on (a seek after
a seek that gave up); the latest seek that fails keeps the request; a skip, next, previous,
load, new queue, play or retry takes it over and plays its track (both platforms). On the
standard backend while another track loads (a natural advance, which the seek cancels) it goes
back paused (before: it acted on the track that failed). With no active track the seek resolves
and does nothing, as crossfade's (a cancel left none, or a backend switch restored none; before:
`standard_seek_unavailable`), except after the first track failed to load: then the seek retries
the track that failed (owner decision, 2026-11-17; crossfade does nothing there), and plays once
done when the play request was kept (pending the owner's confirmation, with the other differences
the README lists); when it fails as well, the next play retries it again.

| Param   | Type     | Description             |
| ------- | -------- | ----------------------- |
| seconds | `number` | The position in seconds |

**Returns:** `Promise<void>`

## `setVolume(volume)`

Sets the volume of the player.

| Param  | Type     | Description                       |
| ------ | -------- | --------------------------------- |
| volume | `number` | The volume in a range from 0 to 1 |

**Returns:** `Promise<void>`

## `getVolume()`

Gets the volume of the player (a number between 0 and 1).

**Returns:** `Promise<number>`

## `setRate(rate)`
Sets the playback rate

| Param  | Type     | Description                       |
| ------ | -------- | --------------------------------- |
| rate   | `number` | The playback rate where 1 is the regular speed |

**Note:** If your rate is high, e.g. above 2, you may want to set the track's `pitchAlgorithm` to something like `PitchAlgorithm.Voice`, or else the default pitch algorithm (which in `SwiftAudioEx` drops down to `AVAudioTimePitchAlgorithm.lowQualityZeroLatency`) will likely
drop words in your audio.

## `getRate()`

Gets the playback rate, where 1 is the regular speed.

**Returns:** `Promise<number>`

## `getProgress()`

Gets the playback [`Progress`](../objects/progress.md) of the active track.

**Returns:** `Promise<`[Progress](../objects/progress.md)`>`

## `getPlaybackState()`

Gets the [`PlaybackState`](../objects/playback-state.md) of the player.

**Returns:** `Promise<`[PlaybackState](../objects/playback-state.md)`>`

## `getPlayWhenReady()`

Gets the current state of `playWhenReady`.

**Returns:** `Promise<boolean>`

## `setPlayWhenReady(playWhenReady)`

`TrackPlayer.setPlayWhenReady(false)` is the equivalent of `TrackPlayer.pause()`
and `TrackPlayer.setPlayWhenReady(true)` is the equivalent of
`TrackPlayer.play()`.

| Param  | Type     | Description                       |
| ------ | -------- | --------------------------------- |
| playWhenReady | `boolean` | A boolean representing if you want `playWhenReady` set or not. |

## ⚠️ `getState()`

**⚠️ Deprecated**

Gets the playback [`State`](../constants/state.md) of the player.

**Returns:** `Promise<`[State](../constants/state.md)`>`


## ⚠️ `getDuration()`

**⚠️ Deprecated**

Gets the duration of the current track in seconds.

Note: `react-native-track-player` is a streaming library, which means it slowly buffers the track and doesn't know exactly when it ends.
The duration returned by this function is determined through various tricks and *may not be exact or may not be available at all*.

You should only trust the result of this function if you included the `duration` property in the [Track Object](../objects/track.md).

**Returns:** `Promise<number>`

## ⚠️ `getPosition()`

**⚠️ Deprecated**

Gets the position of the current track in seconds.

**Returns:** `Promise<number>`

## ⚠️ `getBufferedPosition()`

**⚠️ Deprecated**

Gets the buffered position of the current track in seconds.

**Returns:** `Promise<number>`
