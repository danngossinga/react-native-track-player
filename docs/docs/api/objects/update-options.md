# UpdateOptions

All parameters are optional. You also only need to specify the ones you want to update.


| Param     | Type       | Description          | Android | iOS | Web |
| --------- | ---------- | -------------------- | ------- | --- | ------- |
| `ratingType` | [RatingType](../constants/rating.md) | The rating type | ✅ | ❌ | ❌ |
| `forwardJumpInterval` | `number` | The interval in seconds for the jump forward buttons (if only one is given then we use that value for both) | ✅ | ✅ | ✅ |
| `backwardJumpInterval` | `number` | The interval in seconds for the jump backward buttons (if only one is given then we use that value for both) | ✅ | ✅ | ✅ |
| `stallTimeoutMs` | `number` | How long, in milliseconds, any of the player's waits for a track may go on with no progress (no new media downloaded or buffered) before it fails (see [`PlayerOptions`](./player-options.md)). Defaults to `10000`. On Android, the players' HTTP connect and read timeouts follow it too (instead of ExoPlayer's fixed 8 s), from the next request, on every track (a loaded or preloaded one too); the crossfade and the standard player alike. Applies to the next wait at once. A value that is not a number from 1 to 2147483646 is ignored. Left out, the current value is kept. Other options left out of an `updateOptions` call (capabilities, progress interval…) are reset, so pass it together with your usual options. | ✅ | ✅ | ❌ |
| `prepareTimeoutMs` | `number` | Crossfade backend: the total limit, in milliseconds, for a track to become ready, even while it progresses (see [`PlayerOptions`](./player-options.md)). Defaults to `60000`. Applies to the next load at once. An iOS crossfade seek (which had no limit before) now fails after `stallTimeoutMs` with no progress or at this limit, and the player then reports an error state. Same bounds and rules as `stallTimeoutMs`. | ✅ | ✅ | ❌ |
| `playStartTimeoutMs` | `number` | Crossfade backend (iOS and Android; a failed start pauses, rejects the command with `crossfade_play_start_timeout` and emits a `playback-error` event with that code, and a crossfade whose incoming song does not start rejects with `crossfade_start_failed` (and a `crossfade-state` error) while the outgoing song plays on, the same on both platforms; the resume of a fade paused mid-way does not wait): the total limit, in milliseconds, for playback to start (after `play`, a load that plays at once, or the incoming song of a crossfade). Defaults to `60000`. On iOS, a backend switch and the play used to resume after an interruption wait at most this plus `prepareTimeoutMs` plus 5 s (at least 10 s); on Android these steps do not block a thread and are bounded by the load and play-start waits themselves. Same bounds and rules as `stallTimeoutMs`. | ✅ | ✅ | ❌ |
| `standardReadyTimeoutMs` | `number` | Standard backend: the total limit, in milliseconds, for a track restored by a backend switch to be ready. Defaults to `60000`. Same bounds and rules as `stallTimeoutMs`. | ✅ | ✅ | ❌ |
| `standardSeekTimeoutMs` | `number` | Standard backend (iOS and Android): the total limit, in milliseconds, for a seek (`standard_seek_timeout`). Defaults to `60000`. Same bounds and rules as `stallTimeoutMs`. | ✅ | ✅ | ❌ |
| `incomingStallGraceMs` | `number` | Crossfade backend: how long, in milliseconds, a crossfade waits for the incoming track to start moving before it falls back to playing that track alone (see [`PlayerOptions`](./player-options.md)). Defaults to `2000`. Applies to the next fade step. Same bounds and rules as `stallTimeoutMs`. | ✅ | ✅ | ❌ |
| `initialBitrateEstimateBps` | `number` | Android (crossfade and standard backends): the bandwidth, in bits per second, each track starts from before the player has measured the network (see [`PlayerOptions`](./player-options.md)). Defaults to `96000`. It is a start-of-track estimate: a new value is used at the next track start; the playing track is not reset mid-track (its rendition follows the measured bandwidth). A value that is not a number from 1 to 2147483646 is ignored. Left out, the current value is kept. | ✅ | ❌ | ❌ |
| `android` | [`AndroidOptions`](./android-options.md) | Whether the player will pause playback when the app closes | ✅ | ❌ | ❌ |
| `likeOptions` | [FeedbackOptions](../objects/feedback.md) | The media controls that will be enabled | ❌ | ✅ | ❌ |
| `dislikeOptions` | [FeedbackOptions](../objects/feedback.md) | The media controls that will be enabled | ❌ | ✅ | ❌ |
| `bookmarkOptions` | [FeedbackOptions](../objects/feedback.md) | The media controls that will be enabled | ❌ | ✅ | ❌ |
| `capabilities` | [Capability[]](../constants/capability.md) | The media controls that will be enabled | ✅ | ✅ | ❌ |
| `notificationCapabilities` | [Capability[]](../constants/capability.md) | The buttons that it will show in the notification. Defaults to `data.capabilities`  | ✅ | ❌ | ❌ |
| `compactCapabilities` | [Capability[]](../constants/capability.md) | The buttons that it will show in the compact notification | ✅ | ❌ | ❌ |
| `icon` | [Resource Object](../objects/resource.md) | The notification icon¹ | ✅ | ❌ | ❌ |
| `playIcon` | [Resource Object](../objects/resource.md) | The play icon¹ | ✅ | ❌ | ❌ |
| `pauseIcon` | [Resource Object](../objects/resource.md) | The pause icon¹ | ✅ | ❌ | ❌ |
| `stopIcon` | [Resource Object](../objects/resource.md) | The stop icon¹ | ✅ | ❌ | ❌ |
| `previousIcon` | [Resource Object](../objects/resource.md) | The previous icon¹ | ✅ | ❌ | ❌ |
| `nextIcon` | [Resource Object](../objects/resource.md) | The next icon¹ | ✅ | ❌ | ❌ |
| `rewindIcon` | [Resource Object](../objects/resource.md) | The jump backward icon¹ | ✅ | ❌ | ❌ |
| `forwardIcon` | [Resource Object](../objects/resource.md) | The jump forward icon¹ | ✅ | ❌ | ❌ |
| `color` | `number` | The notification color in an ARGB hex | ✅ | ❌ | ❌ |
| `progressUpdateEventInterval` | `number` | The interval (in seconds) that the [`Event.PlaybackProgressUpdated`](../events.md#playbackprogressupdated) will be fired. `undefined` by default. | ✅ | ✅ | ✅ |

*¹ - The custom icons will only work in release builds*
