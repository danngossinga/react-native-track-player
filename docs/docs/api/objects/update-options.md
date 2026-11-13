# UpdateOptions

All parameters are optional. You also only need to specify the ones you want to update.


| Param     | Type       | Description          | Android | iOS | Web |
| --------- | ---------- | -------------------- | ------- | --- | ------- |
| `ratingType` | [RatingType](../constants/rating.md) | The rating type | ✅ | ❌ | ❌ |
| `forwardJumpInterval` | `number` | The interval in seconds for the jump forward buttons (if only one is given then we use that value for both) | ✅ | ✅ | ✅ |
| `backwardJumpInterval` | `number` | The interval in seconds for the jump backward buttons (if only one is given then we use that value for both) | ✅ | ✅ | ✅ |
| `prepareTimeoutMs` | `number` | Crossfade backend: how long, in milliseconds, a track may take to become ready (see [`PlayerOptions`](./player-options.md)). Applies to the next load at once. A value that is not a number from 1 to 2147483646 is ignored. Left out, the current value is kept. Other options left out of an `updateOptions` call (capabilities, progress interval…) are reset, so pass it together with your usual options. | ✅ | ✅ | ❌ |
| `playStartTimeoutMs` | `number` | iOS crossfade backend: how long, in milliseconds, playback may take to start after `play`. Defaults to `8000`. Same bounds and rules as `prepareTimeoutMs`. | ❌ | ✅ | ❌ |
| `standardReadyTimeoutMs` | `number` | Standard backend: how long, in milliseconds, a track restored by a backend switch may take to be ready. Defaults to `5000`. Same bounds and rules as `prepareTimeoutMs`. | ✅ | ✅ | ❌ |
| `standardSeekTimeoutMs` | `number` | iOS standard backend: how long, in milliseconds, a seek may take (`standard_seek_timeout`). Defaults to `25000`. Same bounds and rules as `prepareTimeoutMs`. | ❌ | ✅ | ❌ |
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
