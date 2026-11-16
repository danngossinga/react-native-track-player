# Vendored KotlinAudio

- Upstream: https://github.com/doublesymmetry/KotlinAudio
- Tag: `v2.1.0`, commit `bf71120704bfe4be2311cf86fc1e2ee1c3c702b7`
- Archive: `KotlinAudio-v2.1.0.tar.gz`, sha256
  `30037455ea1695ce265dd111d0e3f0eccadf7a15f1ab640bb6f60da6b8f9a59d`
- License: Apache License 2.0, see `LICENSE` (copied from the archive; the archive has no NOTICE
  file). Copyright belongs to its authors; changes below are this fork's.
- Copied: `kotlin-audio/src/main/java` and `kotlin-audio/src/main/res` only (no build files,
  tests or example app). Built as part of `react-native-track-player` (see `android/build.gradle`,
  `sourceSets`), replacing the JitPack artifact `com.github.doublesymmetry:kotlinaudio:v2.1.0`;
  its dependencies (coil 2.2.0, ExoPlayer 2.19.0 and its media session extension, timber 5.0.1)
  are declared there at the same versions.

Why: the standard (non-crossfade) Android player must behave like the crossfade path and iOS
(owner decision, strict parity): each track starts from a low bandwidth estimate
(`initialBitrateEstimateBps`), HTTP timeouts follow `stallTimeoutMs` per request, and audio focus
pauses and resumes like the other backends. KotlinAudio builds its ExoPlayer and HTTP sources
privately, so these need small changes in it.

## Modified lines (everything else is upstream as-is)

- `java/com/doublesymmetry/kotlinaudio/notification/NotificationManager.kt:23`:
  `import com.doublesymmetry.kotlinaudio.R` → `import com.doublesymmetry.trackplayer.R` (the
  resources are now merged into this library's namespace).
- `java/com/doublesymmetry/kotlinaudio/models/PlayerHooks.kt`: new file, the hooks below
  (defaults keep upstream behaviour).
- `players/BaseAudioPlayer.kt`:
  - `:35` import of `PlayerHooks`;
  - `:87-88` constructor parameter `hooks: PlayerHooks = PlayerHooks()`;
  - `:235` `hooks.configureExoPlayer(this)` before the ExoPlayer is built (the host sets a track
    selector whose selections start each track from `initialBitrateEstimateBps`);
  - `:477-487` the item's HTTP configuration (user agent, redirects, headers) becomes a
    `configureHttp` block, given to `hooks.httpDataSourceFactory` when set (the host's factory
    builds each request with the current `stallTimeoutMs` as its connect and read timeouts), else
    applied to a plain `DefaultHttpDataSource.Factory` as upstream.
- `players/QueuedAudioPlayer.kt:17-19`: constructor parameter `hooks`, passed to
  `BaseAudioPlayer`.
- Audio focus (DJE-204/205), same file and `models/PlayerHooks.kt`:
  - `PlayerHooks.onAudioFocusChange`: when set, `onAudioFocusChange` gives the focus up on a
    permanent loss and passes every change to the host, without ducking or emitting its own
    event (the host pauses and resumes with one rule for every backend);
  - `requestAudioFocus`: `setWillPauseWhenDucked(... || hooks.onAudioFocusChange != null)`, so a
    can-duck loss is reported to the host (which pauses) instead of ducked by the system.
