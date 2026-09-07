# PlayerOptions

All parameters are optional. You also only need to specify the ones you want to update.

`PlayerOptions` are consumed by the one-time `setupPlayer()` lifecycle operation; they are not a runtime backend selection surface. Use `setPlaybackBackend({ type: 'standard' })` or `setPlaybackBackend({ type: 'pingPong' })` for runtime backend changes; the `pingPong` variant optionally accepts `engineMode: 'orchestratedDualEngine'`. `setPlaybackBackend()` is the sole runtime backend mutation API, and RNTP owns the ping-pong engines and crossfade orchestration.

The setup-only `crossfadeEngineMode` option remains source-compatible but is deprecated. Both `orchestratedDualEngine` and the historical `legacyHybrid` value select the same RNTP-owned orchestrated engine; no legacy playback owner remains.

| Param | Type | Description | Android | iOS |
|-------|------|-------------|---------|-----|
| `minBuffer` | `number` | Minimum duration of media that the player will attempt to buffer in seconds. | ✅ | ✅ |
| `maxBuffer` | `number` | Maximum duration of media that the player will attempt to buffer in seconds. | ✅ | ❌ |
| `backBuffer` | `number` | Duration in seconds that should be kept in the buffer behind the current playhead time. | ✅ | ❌ |
| `playBuffer` | `number` | Duration of media in seconds that must be buffered for playback to start or resume following a user action such as a seek. | ✅ | ❌ |
| `maxCacheSize` | `number` | Maximum cache size in kilobytes. | ✅ | ❌ |
| `iosCategory` | [`IOSCategory`](../constants/ios-category.md) | An [`IOSCategory`](../constants/ios-category.md). Sets on `play()`. | ❌ | ✅  |
| `iosCategoryMode` | [`IOSCategoryMode`](../constants/ios-category-mode.md) | The audio session mode, together with the audio session category, indicates to the system how you intend to use audio in your app. You can use a mode to configure the audio system for specific use cases such as video recording, voice or video chat, or audio analysis. Sets on `play()`. | ❌ | ✅  |
| `iosCategoryOptions` | [`IOSCategoryOptions[]`](../constants/ios-category-options.md) | An array of [`IOSCategoryOptions`](../constants/ios-category-options.md). Sets on `play()`. | ❌ | ✅  |
| `waitForBuffer` | `boolean` | Indicates whether the player should automatically delay playback in order to minimize stalling. Defaults to `true`. @deprecated This option has been nominated for removal in a future version of RNTP. If you have this set to `true`, you can safely remove this from the options. If you are setting this to `false` and have a reason for that, please post a comment in the following discussion: https://github.com/doublesymmetry/react-native-track-player/pull/1695 and describe why you are doing so. | ✅ | ✅ |
| `autoUpdateMetadata` | `boolean` | Indicates whether the player should automatically update now playing metadata data in control center / notification. Defaults to `true`. | ✅ | ✅ |
| `autoHandleInterruptions` | `boolean` | Indicates whether the player should automatically handle audio interruptions. Defaults to `false`. | ✅ | ✅ |
| `crossfade` | `boolean` | Enables the RNTP-owned ping-pong playback backend during one-time setup. Defaults to `false`. | ✅ | ✅ |
| `crossfadeEngineMode` | `'orchestratedDualEngine' \| 'legacyHybrid'` | Deprecated source-compatibility alias. Both values select the orchestrated dual engine; omit for new integrations. | ❌ | ✅ |
| `androidAudioContentType` | `boolean` | The audio content type indicates to the android system how you intend to use audio in your app. With `autoHandleInterruptions: true` and `androidAudioContentType: AndroidAudioContentType.Speech`, the audio will be paused during short interruptions, such as when a message arrives. Otherwise the playback volume is reduced while the notification is playing. Defaults to `AndroidAudioContentType.Music` | ✅ | ❌ |
