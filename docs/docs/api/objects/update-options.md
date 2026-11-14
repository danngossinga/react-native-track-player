# UpdateOptions

All parameters are optional. You also only need to specify the ones you want to update.


| Param     | Type       | Description          | Android | iOS | Web |
| --------- | ---------- | -------------------- | ------- | --- | ------- |
| `ratingType` | [RatingType](../constants/rating.md) | The rating type | ✅ | ❌ | ❌ |
| `forwardJumpInterval` | `number` | The interval in seconds for the jump forward buttons (if only one is given then we use that value for both) | ✅ | ✅ | ✅ |
| `backwardJumpInterval` | `number` | The interval in seconds for the jump backward buttons (if only one is given then we use that value for both) | ✅ | ✅ | ✅ |
| `stallTimeoutMs` | `number` | How long, in milliseconds, any of the player's waits for a track may go on with no progress (no new media downloaded or buffered) before it fails (see [`PlayerOptions`](./player-options.md)). Defaults to `10000`. Applies to the next wait at once. A value that is not a number from 1 to 2147483646 is ignored. Left out, the current value is kept. Other options left out of an `updateOptions` call (capabilities, progress interval…) are reset, so pass it together with your usual options. | ✅ | ✅ | ❌ |
| `prepareTimeoutMs` | `number` | Crossfade backend: the total limit, in milliseconds, for a track to become ready, even while it progresses (see [`PlayerOptions`](./player-options.md)). Defaults to `60000`. Applies to the next load at once. Same bounds and rules as `stallTimeoutMs`. | ✅ | ✅ | ❌ |
| `playStartTimeoutMs` | `number` | iOS crossfade backend: the total limit, in milliseconds, for playback to start (after `play`, a load that plays at once, or the incoming song of a crossfade). Defaults to `60000`. A backend switch and the play used to resume after an interruption wait at most this plus `prepareTimeoutMs` plus 5 s (at least 10 s). Same bounds and rules as `stallTimeoutMs`. | ❌ | ✅ | ❌ |
| `standardReadyTimeoutMs` | `number` | Standard backend: the total limit, in milliseconds, for a track restored by a backend switch to be ready. Defaults to `60000`. Same bounds and rules as `stallTimeoutMs`. | ✅ | ✅ | ❌ |
| `standardSeekTimeoutMs` | `number` | iOS standard backend: the total limit, in milliseconds, for a seek (`standard_seek_timeout`). Defaults to `60000`. Same bounds and rules as `stallTimeoutMs`. | ❌ | ✅ | ❌ |
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
