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

Each modified upstream file starts with a notice that it was modified (Apache License 2.0,
section 4(b)); line numbers below include that notice.

- `java/com/doublesymmetry/kotlinaudio/notification/NotificationManager.kt`: `:1-4` the notice;
  `:27` `import com.doublesymmetry.kotlinaudio.R` → `import com.doublesymmetry.trackplayer.R` (the
  resources are now merged into this library's namespace).
- `java/com/doublesymmetry/kotlinaudio/models/PlayerHooks.kt`: new file, the hooks below
  (defaults keep upstream behaviour), including `mediaTransferListener` and `playlistTransferListener`
  (the media requests' and the playlist requests' bytes: a load's progress for the host's load
  watch).
- `players/BaseAudioPlayer.kt`:
  - `:1-4` the notice;
  - `:39` import of `PlayerHooks`; `:70` import of `HlsDataSourceFactory`;
  - `:91-92` constructor parameter `hooks: PlayerHooks = PlayerHooks()`;
  - `:113-114` audio focus (DJE-204/205): with `hooks.hostOwnsAudioFocus`, the player never
    requests (upstream: when it becomes READY, even while paused) nor abandons the focus, so it
    neither ducks nor emits its own focus event. The host holds one focus for both backends,
    requested at the user's play and at an interruption's resume, and applies one interruption
    rule (pause, then resume) itself;
  - `:241` `hooks.configureExoPlayer(this)` before the ExoPlayer is built (the host sets a track
    selector whose selections start each track from `initialBitrateEstimateBps`);
  - `:496-505` the item's HTTP configuration (user agent, redirects, headers) becomes a
    `configureHttp` block, given to `hooks.httpDataSourceFactory` when set (the host's factory
    builds each request with the current `stallTimeoutMs` as its connect and read timeouts), else
    applied to a plain `DefaultHttpDataSource.Factory` as upstream;
  - `:511-542` media requests and the rest are split: the media requests (HLS segments, DASH
    and SmoothStreaming chunks, a progressive file) report their bytes to
    `hooks.mediaTransferListener`, the playlists, manifests and keys to
    `hooks.playlistTransferListener` (HLS through an `HlsDataSourceFactory` by data type): the
    host counts playlists as progress until the first segment is asked for, as the crossfade
    engines;
  - `:423-434` `failLoad(error, report)` (new): the host's load watch (`StandardLoadWatch`) and
    seek wait give up on a load or seek with no progress for `stallTimeoutMs`, as the crossfade
    path does: the player stops loading at once and goes to the error state with the host's error
    (reported as a playback error for a load no command waits for).
- `models/PlaybackError.kt`: `:1-4` the notice; `:10-11` `fromHost` (new, default false): the
  error's code is the host's own (`crossfade_prepare_timeout`, `standard_seek_timeout`), emitted
  without the `android-` prefix of ExoPlayer's codes.
- `players/QueuedAudioPlayer.kt`: `:1-4` the notice; `:21-23` constructor parameter `hooks`,
  passed to `BaseAudioPlayer`.
