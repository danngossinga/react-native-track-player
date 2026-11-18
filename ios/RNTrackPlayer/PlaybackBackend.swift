import AVFoundation
import Foundation

// Every wait for a track gives up when it makes no progress for `stallTimeoutMs`, or when it
// exceeds its own total limit (the options below), a safety cap for slow but progressing loads.

/// How long a crossfade engine's load may take in all (`prepareTimeoutMs`, setupPlayer or
/// updateOptions): the asset's playable stage, the wait for a ready item, and the seek to the
/// start position and preroll; also the limit of a crossfade engine's seek (as on Android).
let prepareTimeoutDefaultMs = 60000
/// How long a crossfade engine may take in all to start playback after `play` (`playStartTimeoutMs`).
let playStartTimeoutDefaultMs = 60000
/// How long the standard backend may take in all for a restored track to be ready (`standardReadyTimeoutMs`).
let standardReadyTimeoutDefaultMs = 60000
/// `backendSwitchPositionToleranceMs`: how far a restored position may be off at a backend switch.
let backendSwitchPositionToleranceDefaultMs = 750
/// How long the standard backend may take in all to complete a seek (`standardSeekTimeoutMs`).
let standardSeekTimeoutDefaultMs = 60000
/// How long any of those waits goes on with no progress (no new media loaded) before it fails
/// (`stallTimeoutMs`).
let stallTimeoutDefaultMs = 10000
/// How often a callback-driven wait (crossfade engine, standard seek) reads its progress, in
/// milliseconds. A poll interval, not a limit: a wait fails at most this much after its limit.
let stallCheckIntervalMs = 250
/// How long a crossfade waits for the incoming track's time to move before it falls back to
/// playing that track alone (`incomingStallGraceMs`).
let incomingStallGraceDefaultMs = 2000

/// Whether a running crossfade should give up on its incoming track: `graceMs` (the app's
/// `incomingStallGraceMs`) have passed and the incoming track has not moved past `toleranceSeconds`.
func crossfadeIncomingStalled(
    elapsedMs: Int,
    graceMs: Int,
    incomingTime: Double,
    incomingStartTime: Double,
    toleranceSeconds: Double = 0.2
) -> Bool {
    return elapsedMs >= graceMs && incomingTime <= incomingStartTime + toleranceSeconds
}

/// What a wait does after reading its progress.
enum StallVerdict: Equatable {
    /// Keep waiting.
    case wait
    /// No progress for the stall timeout.
    case stalled
    /// The wait's total limit is exceeded, progress or not.
    case capExceeded
}

/// Decides when a wait gives up: after `stallTimeoutMs` with no progress, or after
/// `totalTimeoutMs` in all. It is fed readings (for example the seconds of media loaded) and the
/// time; a reading that grows from the previous one is progress. A reading that drops (a seek
/// back) is not progress, but the next growth from there is.
struct StallWatch: Equatable {
    let stallTimeoutMs: Int
    let totalTimeoutMs: Int
    private let startedAt: TimeInterval
    private var lastProgressAt: TimeInterval
    private var previous: [Double]?

    /// `startedAt` and every later time are seconds on one monotonic clock.
    init(stallTimeoutMs: Int, totalTimeoutMs: Int, startedAt: TimeInterval) {
        self.stallTimeoutMs = stallTimeoutMs
        self.totalTimeoutMs = totalTimeoutMs
        self.startedAt = startedAt
        self.lastProgressAt = startedAt
    }

    /// Takes the current readings. The first ones only set the baseline.
    mutating func check(at now: TimeInterval, readings: [Double]) -> StallVerdict {
        if let previous = previous, previous.count == readings.count,
           zip(readings, previous).contains(where: { $0 > $1 }) {
            lastProgressAt = now
        }
        previous = readings
        return verdict(at: now)
    }

    /// Counts as progress without a reading (a stage reached, such as a playable asset); the
    /// next readings set a new baseline.
    mutating func noteProgress(at now: TimeInterval) {
        lastProgressAt = now
        previous = nil
    }

    /// When the wait gives up if nothing progresses from now on (same clock as `check`).
    func deadline() -> TimeInterval {
        return min(lastProgressAt + Double(stallTimeoutMs) / 1000, startedAt + Double(totalTimeoutMs) / 1000)
    }

    /// For a stage with no progress signal (the asset's playable stage): only the total limit.
    func capVerdict(at now: TimeInterval) -> StallVerdict {
        return (now - startedAt) * 1000 >= Double(totalTimeoutMs) ? .capExceeded : .wait
    }

    /// When the total limit ends the wait (same clock as `check`): the deadline of a stage with no
    /// progress signal.
    func capDeadline() -> TimeInterval {
        return startedAt + Double(totalTimeoutMs) / 1000
    }

    private func verdict(at now: TimeInterval) -> StallVerdict {
        if capVerdict(at: now) == .capExceeded { return .capExceeded }
        if (now - lastProgressAt) * 1000 >= Double(stallTimeoutMs) { return .stalled }
        return .wait
    }
}

/// One reading of an AVPlayerItem's loading, as a crossfade wait sees it. Measured on the iOS
/// 26.5 simulator with a real AVPlayer and a local HLS server (packed AAC and AES-128 CMAF/fMP4):
/// - the loaded time ranges grow while a segment arrives, partial bytes included, on the loads
///   measured; after a CMAF seek they did not grow until the target's segment had arrived;
/// - the access log's bytes are media only (playlists and error bodies never count). They can be
///   posted late: a packed-audio segment's bytes when it completes, and the partial bytes of a
///   variant's failed requests when the player leaves that variant;
/// - after a failed segment mid-track, the new variant downloads again the segments before the
///   failed one: bytes for media already buffered. The loaded ranges cover no new time, but they
///   can empty (on fMP4) and fill again with the same time at the switch;
/// - a failed request adds an error-log entry; a variant switch adds access-log events, and so
///   does a seek past the buffer. Every event's URI is nil and a variant that loaded nothing has
///   no indicated bitrate, so the counts are the signal. The first event is the first variant's
///   (with fMP4 it opens with the first segment request, its bytes growing in flight).
struct ItemLoadSnapshot: Equatable {
    /// The loaded time ranges, in seconds of the item's timeline.
    var loadedRanges: [ClosedRange<Double>]
    var transferredBytes: Double
    var accessLogEvents: Int
    var errorLogEntries: Int
}

extension ItemLoadSnapshot {
    init(of item: AVPlayerItem) {
        loadedRanges = item.loadedTimeRanges.compactMap { value in
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = start + range.duration.seconds
            return start.isFinite && end.isFinite && end >= start ? start...end : nil
        }
        let events = item.accessLog()?.events ?? []
        transferredBytes = events.reduce(0.0) { total, event in
            total + Double(max(0, event.numberOfBytesTransferred))
        }
        accessLogEvents = events.count
        errorLogEntries = item.errorLog()?.events.count ?? 0
    }
}

/// The time a wait has seen buffered: the union of every loaded range it read. It grows only
/// when media of a time not buffered before in this wait arrives: a buffer that empties and
/// fills again with the same time adds nothing, while a seek's new range does.
struct BufferedTimeSeen: Equatable {
    private(set) var ranges: [ClosedRange<Double>] = []

    var seconds: Double { ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

    /// Adds these ranges; returns the seconds of time they add.
    mutating func add(_ newRanges: [ClosedRange<Double>]) -> Double {
        let before = seconds
        var merged: [ClosedRange<Double>] = []
        for range in (ranges + newRanges).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        ranges = merged
        return seconds - before
    }
}

/// Whether a wait counts the bytes its item's access log posts.
enum ItemByteCounting: Equatable {
    /// The posted bytes are progress, with new buffered time.
    case counting
    /// A request failed, or a new access-log event opened that is neither the first variant's
    /// nor that of a seek the wait noted (a switch): the bytes posted now (the left variant's
    /// failed transfers, segments downloaded again) are not progress. New buffered time is, and
    /// it resumes the count, unless the same reading brings another failure or event.
    case pausedUntilMedia
}

/// One wait's progress, read from its item: [seconds of time buffered, counted bytes], both
/// running totals, for a `StallWatch`. A new error-log entry, or an access-log event that is
/// neither the first variant's nor that of a seek the wait issued (`noteSeek`), pauses the byte
/// count (`ItemByteCounting`). Each wait has its own (a load, a seek, a play start), so a switch
/// during one never affects another, on this engine or the other.
struct ItemLoadProgress {
    private(set) var byteCounting: ItemByteCounting = .counting
    private var previous: ItemLoadSnapshot?
    private var buffered = BufferedTimeSeen()
    private var countedBytes: Double = 0
    /// Seeks the wait issued whose access-log event has not appeared yet.
    private var seeksAwaitingEvent = 0

    /// The wait is about to issue a seek; `snapshot` is its item just before it. A seek past the
    /// buffer opens an access-log event (about 0.1 s later on the simulator), which is not a
    /// switch. When the wait has no reading yet, this one is its baseline, so the seek's event
    /// comes after it and is matched however many polls later it appears. When it already has
    /// one (the load's seek to its start position), the note takes none: an event or bytes since
    /// the last poll are judged in the next reading together with the seek's event, so a switch
    /// just before the seek counts as a switch and the bytes posted with it are not progress.
    mutating func noteSeek(before snapshot: ItemLoadSnapshot) {
        seeksAwaitingEvent += 1
        if previous == nil {
            _ = readings(for: snapshot)
        }
    }

    /// The seek completed; `snapshot` is its item now. A seek past the buffer usually opens its
    /// event before completing, and this reading then matches it; what is left of the allowance
    /// (a seek inside the buffer opens no event) is dropped. On packed AAC the event was first
    /// seen in the poll just after the completion: it then counts as a switch, the bytes posted
    /// with it are not progress (they are not counted later either), and progress comes from
    /// the new buffered time the moved buffer brings at once.
    mutating func seekFinished(after snapshot: ItemLoadSnapshot) {
        _ = readings(for: snapshot)
        seeksAwaitingEvent = 0
    }

    /// The readings for this snapshot. The first one only sets the baseline.
    mutating func readings(for snapshot: ItemLoadSnapshot) -> [Double] {
        defer { previous = snapshot }
        let newTime = buffered.add(snapshot.loadedRanges)
        guard let previous = previous else {
            countedBytes = snapshot.transferredBytes
            return [buffered.seconds, countedBytes]
        }
        // New events beyond the first variant's and the seeks' are a switch (several at once too).
        let firstEvent = previous.accessLogEvents == 0 ? 1 : 0
        let newEvents = max(0, snapshot.accessLogEvents - previous.accessLogEvents - firstEvent)
        let seekEvents = min(newEvents, seeksAwaitingEvent)
        seeksAwaitingEvent -= seekEvents
        let failedOrSwitched = snapshot.errorLogEntries > previous.errorLogEntries
            || newEvents > seekEvents
        let newBytes = max(0, snapshot.transferredBytes - previous.transferredBytes)
        if failedOrSwitched {
            byteCounting = .pausedUntilMedia
        } else if byteCounting == .pausedUntilMedia, newTime > 0 {
            byteCounting = .counting
        }
        if byteCounting == .counting {
            countedBytes += newBytes
        }
        return [buffered.seconds, countedBytes]
    }
}

/// One wait's reader of its item's progress (see `ItemLoadProgress`): create one per wait.
final class ItemLoadReader<Item> {
    private var progress = ItemLoadProgress()
    private let snapshot: (Item) -> ItemLoadSnapshot

    init(_ snapshot: @escaping (Item) -> ItemLoadSnapshot) {
        self.snapshot = snapshot
    }

    func readings(_ item: Item) -> [Double] {
        return progress.readings(for: snapshot(item))
    }

    /// The wait is about to seek `item` (see `ItemLoadProgress.noteSeek`).
    func noteSeek(before item: Item) {
        progress.noteSeek(before: snapshot(item))
    }

    /// The wait's seek of `item` completed (see `ItemLoadProgress.seekFinished`).
    func seekFinished(after item: Item) {
        progress.seekFinished(after: snapshot(item))
    }
}

/// What the app is told when the track that should follow an ended one fails to start: no
/// command waits for that load, so its failure (a stall at `stallTimeoutMs`, the total limit, a
/// player error) is reported as a playback error with the error's code and message. Nothing is
/// reported when it started, or when a newer command cancelled it (that command reports its own
/// outcome). Same report as Android's.
struct PlaybackAdvanceFailure: Equatable {
    let code: String
    let message: String

    init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// The report for an advance's result: nil for a success or a cancellation.
    init?(_ result: Result<Void, Error>) {
        guard case .failure(let error) = result else { return nil }
        let nsError = error as NSError
        let code = nsError.userInfo["code"] as? String ?? playbackAdvanceFailureDefaultCode
        guard code != "cancelled" else { return nil }
        self.init(code: code, message: nsError.localizedDescription)
    }

    /// The advance's own report: only a load that failed, which leaves the player in error. A
    /// play start that gave up (the player paused) was reported by the play start itself, as
    /// after any play, so it is not reported twice. Same rule as Android's advanceToNextTrack.
    init?(_ result: Result<Void, Error>, playerInError: Bool) {
        guard playerInError else { return nil }
        self.init(result)
    }
}

/// The code of an advance failure whose error names none (a player error), as on Android.
let playbackAdvanceFailureDefaultCode = "crossfade_engine_error"

extension PlaybackAdvanceFailure {
    /// The `PlaybackError` event's body: the same fields as Android's orchestrator sends.
    var eventBody: [String: Any] {
        return ["code": code, "message": message]
    }
}

/// Starts the track after an ended one with `skip` and hands its failure, if any, to `report`
/// (once; nothing for a start or a cancellation). The orchestrator's end observer runs it.
func advanceAfterTrackEnd(
    skip: (@escaping (Result<Void, Error>) -> Void) -> Void,
    /// Whether the player is in error once the skip completed: only a failed load is the
    /// advance's to report (a play start that gave up reported itself).
    playerInError: @escaping () -> Bool = { true },
    report: @escaping (PlaybackAdvanceFailure) -> Void
) {
    skip { result in
        guard let failure = PlaybackAdvanceFailure(result, playerInError: playerInError()) else { return }
        report(failure)
    }
}

extension StallVerdict {
    /// Why a wait gave up, in the words both platforms use (Android `stallVerdictReason`).
    func reason(stallTimeoutMs: Int, totalTimeoutMs: Int) -> String {
        return self == .stalled
            ? "no progress for \(stallTimeoutMs) ms"
            : "over the \(totalTimeoutMs) ms limit"
    }
}

/// A crossfade load's give-up message: the same text on Android, no engine names.
func crossfadeLoadTimeoutMessage(_ reason: String) -> String {
    return "Crossfade engine did not become ready (\(reason))."
}

/// A crossfade seek's give-up message: the same text on Android, no engine names.
func crossfadeSeekTimeoutMessage(_ reason: String) -> String {
    return "Crossfade engine seek did not finish (\(reason))."
}

/// Ends a crossfade load: a load that failed for any reason (a stall, the limit, a player or
/// item error, a failed seek or preroll) stops loading first, as Android's engine does for every
/// failed load; then the caller learns the result.
func settleCrossfadeLoad(
    _ result: Result<Void, Error>,
    stopLoading: () -> Void,
    complete: (Result<Void, Error>) -> Void
) {
    if case .failure = result { stopLoading() }
    complete(result)
}

/// Numbers an engine's seeks. AVPlayer ends a seek unfinished when a newer seek replaces it: that
/// is not a failure of the track, so only the latest seek's failure stops loading.
final class SeekSequence {
    private(set) var latest = 0

    func begin() -> Int {
        latest += 1
        return latest
    }

    func isLatest(_ seek: Int) -> Bool {
        return seek == latest
    }
}

/// Ends a crossfade seek: the latest seek that failed for any reason (a stall, the limit, an
/// unfinished seek, an item error) stops loading first, as Android's engine does for every failed
/// seek; a seek a newer one replaced does not. Then the caller learns the result.
func settleCrossfadeSeek(
    _ result: Result<Void, Error>,
    isLatest: Bool,
    stopLoading: () -> Void,
    complete: (Result<Void, Error>) -> Void
) {
    if case .failure = result, isLatest { stopLoading() }
    complete(result)
}

/// The player a crossfade engine stops loading on (AVPlayer; tests may pass another).
protocol ItemLoadingPlayer: AnyObject {
    func replaceCurrentItem(with item: AVPlayerItem?)
}

extension AVPlayer: ItemLoadingPlayer {}

/// Stops a load or seek the engine gave up on: the item leaves the player, so it stops
/// requesting the item's media (it would otherwise keep a stalled request going in the
/// background). As Android's engine stops its player.
func stopLoading(_ player: ItemLoadingPlayer) {
    player.replaceCurrentItem(with: nil)
}

/// A timeout option (`prepareTimeoutMs`, `playStartTimeoutMs`...), in milliseconds: nil when it is
/// not a number from 1 to 2147483646 (booleans refused), so the current value is kept. Same bounds
/// as Android.
func timeoutOption(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let ms = number.doubleValue
    guard ms.isFinite, ms >= 1, ms < Double(Int32.max) else { return nil }
    return Int(ms)
}

/// One of the app's timeouts: one value, written from the module's queue and read by the engines
/// (main) and the backends (facade queues), so it is locked.
final class TimeoutSetting {
    let optionKey: String
    private let lock = NSLock()
    private var value: Int

    init(optionKey: String, defaultMs: Int) {
        self.optionKey = optionKey
        self.value = defaultMs
    }

    var milliseconds: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Takes a valid value of its option from setup or update options. Returns what happened:
    /// nil when the options do not carry it, false when its value was ignored, true when taken.
    @discardableResult
    func apply(_ options: [String: Any]) -> Bool? {
        guard let raw = options[optionKey] else { return nil }
        guard let timeout = timeoutOption(raw) else { return false }
        lock.lock()
        value = timeout
        lock.unlock()
        return true
    }
}

/// What the player does on an interruption event (DJE-204/205/206; Android has the same policy).
enum InterruptionAction: Equatable {
    case none
    case pause
    case resume
}

/// A user play: start it, or refuse it because the system keeps the audio (Android: the same).
enum UserPlayDecision: Equatable {
    case play
    case refused
}

/// What the module does for an interruption decision: a resume the session refuses is
/// `resumeRefused` (Android: a resume without the audio focus, `onResumeFailed`).
enum InterruptionStep: Equatable {
    case none
    case pause
    case resume
    case resumeRefused
}

/// The code a refused play rejects with and reports (`playback-error`), the same on Android.
let audioFocusRefusedCode = "audio_focus_refused"

/// The rejection codes the module sends to JS as they are, as Android sends every command
/// failure's own code: play start, crossfade, load and seek failures (standard and crossfade
/// seeks: `standard_seek_timeout`, `standard_seek_cancelled`, `standard_seek_unavailable`,
/// `crossfade_seek_timeout`), `cancelled` and a refused audio focus. Any other error rejects with
/// the command's own code (`seek_failed`, `skip_failed`...); `standard_seek_invalid_position` is
/// iOS's alone (Android has no such check) and stays `seek_failed`.
let sharedRejectionCodes: Set<String> = [
    "crossfade_play_start_timeout", "crossfade_engine_error", "crossfade_start_failed", "crossfade_prepare_timeout",
    "crossfade_seek_timeout", "standard_seek_timeout", "standard_seek_cancelled", "standard_seek_unavailable",
    "cancelled", audioFocusRefusedCode,
]

/// The code a command rejects with in JS: the error's own when Android sends the same, else
/// the command's `fallback`.
func bridgeRejectionCode(_ code: String?, fallback: String) -> String {
    guard let code = code, sharedRejectionCodes.contains(code) else { return fallback }
    return code
}

func audioFocusRefusedError() -> Error {
    NSError(domain: "RNTrackPlayer.PlaybackBackend", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "The system did not give the audio to this player (a call or another app holds it).",
        "code": audioFocusRefusedCode
    ])
}

/// A playback backend's error: `message`, with its `code` (the code JS rejects with).
func playbackBackendError(code: String, message: String) -> Error {
    return NSError(domain: "RNTrackPlayer.PlaybackBackend", code: 1, userInfo: [
        NSLocalizedDescriptionKey: message,
        "code": code
    ])
}

/// The `remote-duck` event for an interruption event: `paused` while the audio is taken away,
/// `permanent` when it will not be given back (same meaning on iOS and Android).
struct RemoteDuckPayload: Equatable {
    let paused: Bool
    let permanent: Bool
}

/// The owner's rule for calls, audio focus and headphones: pause when the audio is taken away;
/// when it is given back, resume only if the system allows it, `autoHandleInterruptions` is on,
/// playback was playing when it was taken and the user did not pause or play since. A permanent
/// loss or headphones unplugged pause with no resume. A can-duck loss is treated as a transient
/// loss: pause, then resume (the platforms differ on ducking, so both pause). A second loss during
/// an interruption keeps what the first one recorded (the player is paused by then).
/// Thread-safe: the module calls it from the notification threads and its command queue.
final class InterruptionPolicy {
    /// `autoHandleInterruptions`, read at every interruption end.
    private let autoResume: () -> Bool
    private let lock = NSLock()
    private var resumeOnEnd = false
    /// A call is in progress: an interruption began and has not ended, nor been overtaken by a
    /// permanent loss, headphones unplugged or a play the system allowed. A user pause does not
    /// end it: a play refused after that pause still resumes when the call ends.
    private var interrupted = false

    init(autoResume: @escaping () -> Bool) {
        self.autoResume = autoResume
    }

    func began(isPlaying: Bool) -> (InterruptionAction, RemoteDuckPayload?) {
        lock.lock()
        defer { lock.unlock() }
        if !interrupted { resumeOnEnd = isPlaying }
        interrupted = true
        return (isPlaying ? .pause : .none, RemoteDuckPayload(paused: true, permanent: false))
    }

    func ended(shouldResume: Bool) -> (InterruptionAction, RemoteDuckPayload?) {
        lock.lock()
        let wasToResume = resumeOnEnd
        forgetLocked()
        lock.unlock()
        let resume = shouldResume && wasToResume && autoResume()
        return (resume ? .resume : .none, RemoteDuckPayload(paused: !shouldResume, permanent: !shouldResume))
    }

    func lostPermanently(isPlaying: Bool) -> (InterruptionAction, RemoteDuckPayload?) {
        forget()
        return (isPlaying ? .pause : .none, RemoteDuckPayload(paused: true, permanent: true))
    }

    /// Headphones unplugged (`oldDeviceUnavailable` / becoming noisy).
    func noisy(isPlaying: Bool) -> (InterruptionAction, RemoteDuckPayload?) {
        forget()
        return (isPlaying ? .pause : .none, nil)
    }

    /// A pause from the user (app or remote control): an interruption's end no longer resumes.
    /// The call is still in progress: a play refused after it resumes at its end.
    func userPause() {
        lock.lock()
        resumeOnEnd = false
        lock.unlock()
    }

    /// A stop or a reset from the user: nothing resumes, and the player leaves the call (as on
    /// Android, which gives the focus up): a play refused after it does not resume.
    func userStop() {
        forget()
    }

    /// A play from the user, decided from the system's answer alone (`activate`: iOS activates
    /// the session, Android requests the focus), also after an interruption that began and never
    /// ended: an answer that gives the audio overrules it. See `userPlay(granted:)`.
    func userPlay(activate: () -> Bool) -> UserPlayDecision {
        return userPlay(granted: activate())
    }

    /// What the module does on an interruption decision (decision B): a resume needs the session;
    /// when `activate` fails, the resume is refused (reported as `audio_focus_refused`, not
    /// retried). `activate` runs only for a resume.
    func step(for action: InterruptionAction, activate: () -> Bool) -> InterruptionStep {
        switch action {
        case .none: return .none
        case .pause: return .pause
        case .resume: return activate() ? .resume : .resumeRefused
        }
    }

    /// A play from the user (owner decision B): it starts only if the system gives the audio
    /// (`granted`: iOS activates the session; Android grants the focus).
    /// Granted, the audio is back: no call is in progress any more and nothing resumes at an
    /// interruption's end. Refused, nothing starts now, but the user's last intent is to play: a
    /// call in progress resumes when it ends, also after a user pause during it, if the system
    /// allows it ("pause, then auto-resume"); a later user pause cancels that. Nothing else
    /// retries.
    func userPlay(granted: Bool) -> UserPlayDecision {
        guard granted else {
            lock.lock()
            if interrupted { resumeOnEnd = true }
            lock.unlock()
            return .refused
        }
        forget()
        return .play
    }

    private func forget() {
        lock.lock()
        forgetLocked()
        lock.unlock()
    }

    private func forgetLocked() {
        resumeOnEnd = false
        interrupted = false
    }
}

/// What the module last asked a standard player (play, pause, stop, playWhenReady, a restore),
/// for interruptions: SwiftAudioEx sets its own playWhenReady to false when the system pauses the
/// player (its timeControlStatus observer), which can run before the module reads it when an
/// interruption begins, and would lose the resume. The module's own request does not change then.
struct RequestedPlayback {
    private(set) var playWhenReady = false

    mutating func request(_ value: Bool) {
        playWhenReady = value
    }
}

/// The playback states (`State` raw values) in which nothing plays for an interruption: no active
/// track, the queue ended, an error, stopped.
let interruptionFinishedStates: Set<String> = ["none", "ended", "error", "stopped"]

/// Whether a backend plays as far as an interruption is concerned, the same rule on all four
/// backends (Android: `interruptionCountsAsPlaying`): it was asked to play and has an active
/// track that has not ended, failed or stopped. After the queue ended, an interruption neither
/// pauses nor resumes.
func interruptionCountsAsPlaying(playWhenReady: Bool, stateRawValue: String) -> Bool {
    return playWhenReady && !interruptionFinishedStates.contains(stateRawValue)
}

/// Whether a command that loads or moves the active track (load, skip, seek, retry) starts the
/// audio: playWhenReady is still on but nothing plays (the queue ended, an error...), so the
/// command plays at once. It is then a user play (decision B, Android: `commandStartsPlayback`):
/// an interruption while nothing played paused nothing, so the audio may be another app's or a
/// call's.
func commandStartsPlayback(playWhenReady: Bool, stateRawValue: String) -> Bool {
    return playWhenReady && interruptionFinishedStates.contains(stateRawValue)
}

/// A starting command's result when its play was refused (decision B): it ran paused and fails
/// with `audio_focus_refused`, unless it failed by itself (that failure is kept).
func applyingPlayRefusal<Value>(refused: Bool, to result: Result<Value, Error>) -> Result<Value, Error> {
    guard refused, case .success = result else { return result }
    return .failure(audioFocusRefusedError())
}

/// The native seeks a standard backend issued, to match each SwiftAudioEx seek callback (which
/// carries only the position) to its own seek: a callback belongs to the oldest outstanding native
/// seek at that position. A seek that a newer one replaced keeps its slot (AVPlayer still calls it
/// back, finished or not) but has no owner any more, so after A, B, then A again, only the last
/// A's callback resolves the current seek. A callback for a seek the backend did not issue (the
/// SDK's own) matches nothing. Not thread-safe: use it from one queue (main).
struct NativeSeekLedger<Owner: AnyObject> {
    private var outstanding: [(position: Double, owner: Owner?)] = []

    mutating func issued(_ owner: Owner, at position: Double) {
        outstanding.append((position: position, owner: owner))
    }

    /// The owner gave its seek up (a newer seek replaced it): its callback resolves nothing.
    mutating func release(_ owner: Owner) {
        for index in outstanding.indices where outstanding[index].owner === owner {
            outstanding[index].owner = nil
        }
    }

    /// The owner of the native seek this callback completes, nil when it was replaced or not ours.
    mutating func completed(at position: Double) -> Owner? {
        guard let index = outstanding.firstIndex(where: { $0.position == position }) else { return nil }
        return outstanding.remove(at: index).owner
    }
}

/// One value shared across threads (a setting read by notification handlers, a reference
/// published once setup is done).
final class LockedValue<Value> {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// The order in which a standard player's failure reaches JS: its error state, then the playback
/// error, as Android (KotlinAudio's onPlayerError and failLoad) and the crossfade path.
/// SwiftAudioEx reports a failure at once on its `fail` event, while it sets its failed state on
/// its state queue and emits it on another event queue, so the error came first. One player's
/// state and failure deliveries pass through this, one at a time (its lock): a failure waits for
/// the failed state when that state is still to come (the player is failed, the last state
/// delivered is not), and is emitted right after it.
///
/// One explicit state (form 3): `notFailed` (the last state delivered is not failed), `failed`
/// (it is), `waiting(failures)` (failures waiting for the failed state). Moves: a failed state ->
/// failed, emitting the waiting failures after it; another state -> notFailed, except while
/// waiting (an older state still delivered first: keeps waiting); a failure while failed, or
/// while the player is not failed (no failed state is coming: SwiftAudioEx's failed-to-play-to-end)
/// -> emitted at once; else -> waiting (appended).
final class StandardFailureOrder<Failure> {
    enum State {
        case notFailed
        case failed
        case waiting([Failure])
    }

    private let lock = NSLock()
    private var stored: State = .notFailed

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// A state delivered: `emit` emits it (or the backend holds it back), then the failures
    /// waiting for a failed state are emitted (`emitFailure`), in that order.
    func stateDelivered(failed: Bool, emit: () -> Void, emitFailure: (Failure) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        emit()
        if failed {
            if case let .waiting(failures) = stored {
                stored = .failed
                failures.forEach(emitFailure)
            } else {
                stored = .failed
            }
        } else if case .waiting = stored {
            return
        } else {
            stored = .notFailed
        }
    }

    /// A failure delivered: emitted at once (`emitFailure`) unless the failed state is still to
    /// come (`playerFailed`: the player's state is failed now, read here).
    func failureDelivered(_ failure: Failure, playerFailed: () -> Bool, emitFailure: (Failure) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        switch stored {
        case .failed:
            emitFailure(failure)
        case let .waiting(failures):
            stored = .waiting(failures + [failure])
        case .notFailed:
            if playerFailed() {
                stored = .waiting([failure])
            } else {
                emitFailure(failure)
            }
        }
    }
}

extension StandardFailureOrder.State: Equatable where Failure: Equatable {}

/// Drives one wait on a callback queue: every `intervalMs` it reads the progress and asks its
/// `StallWatch`; it reschedules itself while the verdict is `.wait` and calls `onGiveUp` once
/// otherwise. `readings` returning nil means the wait has no progress signal yet (an asset not
/// yet playable, a seek not yet issued): only the total limit applies then. Each wait owns its
/// driver, so cancelling one never stops another. Not thread-safe: use it from one queue (main).
final class StallWaitDriver {
    typealias Schedule = (_ delayMs: Int, _ work: @escaping () -> Void) -> Void

    private var watch: StallWatch
    private let intervalMs: Int
    private let now: () -> TimeInterval
    private let schedule: Schedule
    // Released when the wait ends (cancel or give-up): they usually hold the caller's completion
    // and the engine, which would otherwise stay alive through the driver.
    private var readings: (() -> [Double]?)?
    private var onGiveUp: ((StallVerdict, StallWatch) -> Void)?
    private(set) var isActive = false

    init(
        stallTimeoutMs: Int,
        totalTimeoutMs: Int,
        intervalMs: Int = stallCheckIntervalMs,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping Schedule = { delayMs, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
        },
        readings: @escaping () -> [Double]?,
        onGiveUp: @escaping (StallVerdict, StallWatch) -> Void
    ) {
        self.watch = StallWatch(stallTimeoutMs: stallTimeoutMs, totalTimeoutMs: totalTimeoutMs, startedAt: now())
        self.intervalMs = intervalMs
        self.now = now
        self.schedule = schedule
        self.readings = readings
        self.onGiveUp = onGiveUp
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        scheduleNext()
    }

    /// Stops the wait: no more checks, `onGiveUp` is never called.
    func cancel() {
        isActive = false
        readings = nil
        onGiveUp = nil
    }

    /// A stage reached (playable asset, ready item, seek issued): restarts the stall clock; the
    /// total limit still counts from the start.
    func noteProgress() {
        watch.noteProgress(at: now())
    }

    private func scheduleNext() {
        schedule(intervalMs) { self.tick() }
    }

    private func tick() {
        guard isActive else { return }
        let at = now()
        let verdict = readings?().map { watch.check(at: at, readings: $0) } ?? watch.capVerdict(at: at)
        guard verdict != .wait else {
            scheduleNext()
            return
        }
        isActive = false
        let giveUp = onGiveUp
        readings = nil
        onGiveUp = nil
        giveUp?(verdict, watch)
    }
}

/// How long a synchronous ping-pong backend step may take (a backend switch, which loads or starts
/// a track, and a rollback; the resume after an interruption does not wait): the load limit plus the play-start limit plus 5 s, never less than 10 s
/// (125 s with both defaults). The waits inside fail sooner when they stall (`stallTimeoutMs`);
/// this only bounds a step whose waits keep progressing.
func backendStepTimeout(loadTimeoutMs: Int, playStartTimeoutMs: Int) -> TimeInterval {
    max(10, TimeInterval(loadTimeoutMs) / 1000 + TimeInterval(playStartTimeoutMs) / 1000 + 5)
}

enum PlaybackBackendKind: String {
    case standard
    case pingPong
}

struct PlaybackBackendSnapshot: Equatable {
    let queueIDs: [String]
    let activeIndex: Int?
    let activeTrackID: String?
    let position: Double
    let playWhenReady: Bool
    let volume: Float
    let rate: Float
    let repeatMode: Int
    let transitionGeneration: Int

    static let empty = PlaybackBackendSnapshot(
        queueIDs: [],
        activeIndex: nil,
        activeTrackID: nil,
        position: 0,
        playWhenReady: false,
        volume: 1,
        rate: 1,
        repeatMode: 0,
        transitionGeneration: 0
    )

    func with(playWhenReady: Bool) -> PlaybackBackendSnapshot {
        return PlaybackBackendSnapshot(
            queueIDs: queueIDs,
            activeIndex: activeIndex,
            activeTrackID: activeTrackID,
            position: position,
            playWhenReady: playWhenReady,
            volume: volume,
            rate: rate,
            repeatMode: repeatMode,
            transitionGeneration: transitionGeneration
        )
    }

    func with(position: Double) -> PlaybackBackendSnapshot {
        return PlaybackBackendSnapshot(
            queueIDs: queueIDs,
            activeIndex: activeIndex,
            activeTrackID: activeTrackID,
            position: position,
            playWhenReady: playWhenReady,
            volume: volume,
            rate: rate,
            repeatMode: repeatMode,
            transitionGeneration: transitionGeneration
        )
    }

    func withIntent(playWhenReady: Bool, volume: Float) -> PlaybackBackendSnapshot {
        return PlaybackBackendSnapshot(
            queueIDs: queueIDs,
            activeIndex: activeIndex,
            activeTrackID: activeTrackID,
            position: position,
            playWhenReady: playWhenReady,
            volume: volume,
            rate: rate,
            repeatMode: repeatMode,
            transitionGeneration: transitionGeneration
        )
    }
}

struct PlaybackTransitionRequest {
    let duration: Double
    let interval: Double
    let targetVolume: Float
    let waitUntil: Double
}

struct PlaybackBackendTransactionResult {
    let backend: PlaybackBackendKind
    let operationID: Int
    let snapshot: PlaybackBackendSnapshot
}

struct PlaybackBackendCleanupDiagnostic {
    let code: String
    let message: String

    static let disposalFailed = PlaybackBackendCleanupDiagnostic(
        code: "playback_backend_cleanup_failed",
        message: "The previous playback backend could not be fully disposed."
    )
}

func playbackBackendQueueForRestore<Item: AnyObject>(
    incoming: [Item]?,
    current: () -> [Item]
) -> [Item] {
    return incoming ?? current()
}

func playbackBackendQueueForRestore<Item: AnyObject>(
    incomingProvider: (() -> [Item])?,
    current: () -> [Item]
) -> [Item] {
    return incomingProvider?() ?? current()
}

func validateStandardPlaybackActivationSnapshot(
    _ snapshot: PlaybackBackendSnapshot,
    queueCount: Int
) throws {
    let hasMatchingQueueCount = snapshot.queueIDs.count == queueCount
    let hasValidIdleState = hasMatchingQueueCount &&
        snapshot.activeIndex == nil &&
        snapshot.activeTrackID == nil &&
        !snapshot.playWhenReady
    let hasCoherentActiveTrack = snapshot.activeIndex.map { index in
        hasMatchingQueueCount &&
            snapshot.queueIDs.indices.contains(index) &&
            snapshot.activeTrackID == snapshot.queueIDs[index]
    } ?? false
    guard hasValidIdleState || hasCoherentActiveTrack else {
        throw NSError(
            domain: "RNTrackPlayer.PlaybackBackend",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The standard playback candidate did not restore the active track.",
                "code": "playback_backend_activation_not_ready"
            ]
        )
    }
}

func performPlaybackBackendOnMainSync<Value>(
    _ operation: () throws -> Value
) throws -> Value {
    if Thread.isMainThread { return try operation() }

    var value: Value?
    var failure: Error?
    DispatchQueue.main.sync {
        do {
            value = try operation()
        } catch {
            failure = error
        }
    }
    if let failure = failure { throw failure }
    return value!
}

protocol PlaybackBackend: AnyObject {
    var kind: PlaybackBackendKind { get }
    var identity: AnyObject { get }
    func settleActiveTransition() throws
    func snapshot() throws -> PlaybackBackendSnapshot
    func beginHandoffQuiescence() throws -> PlaybackBackendSnapshot
    func cancelHandoffQuiescence(_ snapshot: PlaybackBackendSnapshot) throws
    func prepareSilently(_ snapshot: PlaybackBackendSnapshot) throws
    func restore(_ snapshot: PlaybackBackendSnapshot) throws
    func prepareActivation(_ snapshot: PlaybackBackendSnapshot) throws
    func stopAndMute() throws
    func suspendEventDeliveryForHandoff() throws
    func resumeEventDeliveryAfterHandoff(_ snapshot: PlaybackBackendSnapshot)
    func suspendControlSurface() throws
    func resumeControlSurface(_ snapshot: PlaybackBackendSnapshot)
    func activateInitialControlSurface()
    func relinquishExclusiveControlSurfaceBeforeCommit() throws
    func commitQueue(_ snapshot: PlaybackBackendSnapshot)
    func activateAfterCommit(_ snapshot: PlaybackBackendSnapshot)
    func reactivateAfterRollback(_ snapshot: PlaybackBackendSnapshot)
    func play() throws
    func pause()
    func seek(to position: Double) throws
    func startTransition(_ request: PlaybackTransitionRequest) throws
    func dispose() throws
}

extension PlaybackBackend {
    var identity: AnyObject { return self }
    func beginHandoffQuiescence() throws -> PlaybackBackendSnapshot { return try snapshot() }
    func cancelHandoffQuiescence(_ snapshot: PlaybackBackendSnapshot) throws {}
    func suspendEventDeliveryForHandoff() throws {}
    func resumeEventDeliveryAfterHandoff(_ snapshot: PlaybackBackendSnapshot) {
        resumeControlSurface(snapshot)
    }
    func suspendControlSurface() throws {}
    func resumeControlSurface(_ snapshot: PlaybackBackendSnapshot) {}
    func activateInitialControlSurface() {}
    func relinquishExclusiveControlSurfaceBeforeCommit() throws {}
    func prepareActivation(_ snapshot: PlaybackBackendSnapshot) throws {}
    func activateAfterCommit(_ snapshot: PlaybackBackendSnapshot) {}
    func reactivateAfterRollback(_ snapshot: PlaybackBackendSnapshot) {
        resumeControlSurface(snapshot)
    }
}

protocol PlaybackBackendFactory: AnyObject {
    func create(_ kind: PlaybackBackendKind) -> PlaybackBackend
}

final class PlaybackBackendAuthority {
    private struct Owner {
        let kind: PlaybackBackendKind
        let identity: ObjectIdentifier
    }

    private let lock = NSLock()
    private var owner: Owner?

    func publish(_ backend: PlaybackBackend?) {
        lock.lock()
        owner = backend.map { Owner(kind: $0.kind, identity: ObjectIdentifier($0.identity)) }
        lock.unlock()
    }

    func clear() {
        publish(nil)
    }

    func isAuthoritative(_ kind: PlaybackBackendKind, identity: AnyObject) -> Bool {
        return isAuthoritative(kind, identity: ObjectIdentifier(identity))
    }

    func isAuthoritative(_ kind: PlaybackBackendKind, identity: ObjectIdentifier) -> Bool {
        lock.lock()
        let result = owner?.kind == kind && owner?.identity == identity
        lock.unlock()
        return result
    }

    var currentKind: PlaybackBackendKind? {
        lock.lock()
        let result = owner?.kind
        lock.unlock()
        return result
    }

    var currentIdentity: ObjectIdentifier? {
        lock.lock()
        let result = owner?.identity
        lock.unlock()
        return result
    }
}

final class PlaybackTransitionGenerationSidecar {
    private let lock = NSLock()
    private var generation = 0

    func observe(_ observedGeneration: Int) -> Int {
        lock.lock()
        generation = max(generation, max(0, observedGeneration))
        let result = generation
        lock.unlock()
        return result
    }

    func restore(_ snapshotGeneration: Int) {
        _ = observe(snapshotGeneration)
    }

    var current: Int {
        lock.lock()
        let result = generation
        lock.unlock()
        return result
    }
}

final class PlaybackBackendCommandCompletion<Value> {
    private let lock = NSLock()
    private var resolved = false
    private let resolveOnce: (Result<Value, Error>) -> Void

    init(resolve: @escaping (Result<Value, Error>) -> Void) {
        resolveOnce = resolve
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        lock.unlock()
        resolveOnce(result)
    }
}

final class PlaybackBackendExclusiveCommandSlot<Value> {
    private let lock = NSLock()
    private var current: PlaybackBackendCommandCompletion<Value>?

    var isOccupied: Bool {
        lock.lock()
        let result = current != nil
        lock.unlock()
        return result
    }

    func isCurrent(_ completion: PlaybackBackendCommandCompletion<Value>) -> Bool {
        lock.lock()
        let result = current === completion
        lock.unlock()
        return result
    }

    func begin(
        resolve: @escaping (Result<Value, Error>) -> Void
    ) -> PlaybackBackendCommandCompletion<Value>? {
        lock.lock()
        guard current == nil else {
            lock.unlock()
            return nil
        }
        let completion = PlaybackBackendCommandCompletion<Value>(resolve: resolve)
        current = completion
        lock.unlock()
        return completion
    }

    func complete(
        _ completion: PlaybackBackendCommandCompletion<Value>,
        result: Result<Value, Error>
    ) {
        takeResolver(completion, result: result)?()
    }

    func takeResolver(
        _ completion: PlaybackBackendCommandCompletion<Value>,
        result: Result<Value, Error>
    ) -> (() -> Void)? {
        lock.lock()
        guard current === completion else {
            lock.unlock()
            return nil
        }
        current = nil
        lock.unlock()
        return { completion.resolve(result) }
    }

    func cancelCurrent(with error: Error) {
        takeCurrentResolver(result: .failure(error))?()
    }

    func takeCurrentResolver(result: Result<Value, Error>) -> (() -> Void)? {
        lock.lock()
        let completion = current
        current = nil
        lock.unlock()
        guard let completion else { return nil }
        return { completion.resolve(result) }
    }
}

final class PlaybackBackendEventToken {
    private enum State: Equatable {
        case pending
        case active
        case invalid
    }

    private let lock = NSLock()
    private var state = State.pending

    func activate() {
        lock.lock()
        if state == .pending { state = .active }
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        state = .invalid
        lock.unlock()
    }

    var acceptsDelivery: Bool {
        lock.lock()
        let result = state == .active
        lock.unlock()
        return result
    }
}

final class PlaybackBackendOperationTicket {
    fileprivate let generation: UInt64
    private let lock = NSLock()
    private var cancelled = false
    private let onCancel: (String) -> Void

    fileprivate init(generation: UInt64, onCancel: @escaping (String) -> Void) {
        self.generation = generation
        self.onCancel = onCancel
    }

    fileprivate func cancel(reason: String) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        lock.unlock()
        onCancel(reason)
    }
}

final class PlaybackBackendOperationRegistry {
    private let lock = NSRecursiveLock()
    private var generation: UInt64 = 0
    private var current: PlaybackBackendOperationTicket?
    private var mutationDepth = 0
    private var afterMutationActions: [() -> Void] = []

    func begin(onCancel: @escaping (String) -> Void) -> PlaybackBackendOperationTicket {
        lock.lock()
        let previous = current
        generation &+= 1
        let ticket = PlaybackBackendOperationTicket(generation: generation, onCancel: onCancel)
        current = ticket
        lock.unlock()
        previous?.cancel(reason: "superseded")
        return ticket
    }

    func invalidateAll(reason: String) {
        lock.lock()
        let invalidated = current
        current = nil
        lock.unlock()
        invalidated?.cancel(reason: reason)
    }

    func isCurrent(_ ticket: PlaybackBackendOperationTicket) -> Bool {
        lock.lock()
        let result = current === ticket
        lock.unlock()
        return result
    }

    @discardableResult
    func performIfCurrent(
        _ ticket: PlaybackBackendOperationTicket,
        perform: () -> Void
    ) -> Bool {
        lock.lock()
        guard current === ticket else {
            lock.unlock()
            return false
        }
        mutationDepth += 1
        perform()
        mutationDepth -= 1
        let actions = drainAfterMutationActionsIfNeeded()
        lock.unlock()
        actions.forEach { $0() }
        return true
    }

    @discardableResult
    func complete(
        _ ticket: PlaybackBackendOperationTicket,
        perform: () -> Void = {}
    ) -> Bool {
        lock.lock()
        guard current === ticket else {
            lock.unlock()
            return false
        }
        current = nil
        mutationDepth += 1
        perform()
        mutationDepth -= 1
        let actions = drainAfterMutationActionsIfNeeded()
        lock.unlock()
        actions.forEach { $0() }
        return true
    }

    /// Runs `action` only after the outermost registry mutation has released its lock.
    /// This keeps synchronous engine callbacks from invoking command completions while
    /// a registry mutation is still in progress.
    func performAfterCurrentMutation(_ action: @escaping () -> Void) {
        lock.lock()
        guard mutationDepth > 0 else {
            lock.unlock()
            action()
            return
        }
        afterMutationActions.append(action)
        lock.unlock()
    }

    func finish(_ ticket: PlaybackBackendOperationTicket) {
        _ = complete(ticket)
    }

    private func drainAfterMutationActionsIfNeeded() -> [() -> Void] {
        guard mutationDepth == 0 else { return [] }
        let actions = afterMutationActions
        afterMutationActions.removeAll()
        return actions
    }
}

final class PlaybackBackendQueueState<Item> {
    private let lock = NSLock()
    private var pendingValues: [Item]
    private var authoritativeValues: [Item]

    init(_ initial: [Item] = []) {
        pendingValues = initial
        authoritativeValues = initial
    }

    func captureAuthoritative(_ values: [Item]) {
        lock.lock()
        authoritativeValues = values
        lock.unlock()
    }

    func stage(_ values: [Item]) {
        lock.lock()
        pendingValues = values
        lock.unlock()
    }

    var pending: [Item] {
        lock.lock()
        let result = pendingValues
        lock.unlock()
        return result
    }

    var authoritative: [Item] {
        lock.lock()
        let result = authoritativeValues
        lock.unlock()
        return result
    }

    @discardableResult
    func commit() -> [Item] {
        lock.lock()
        authoritativeValues = pendingValues
        let result = authoritativeValues
        lock.unlock()
        return result
    }

    func rollback() -> [Item] {
        lock.lock()
        pendingValues = authoritativeValues
        let result = authoritativeValues
        lock.unlock()
        return result
    }
}

final class PlaybackBackendFacade {
    static let maximumPreparationAttempts = 8

    private struct VersionedSnapshot {
        let snapshot: PlaybackBackendSnapshot
        let version: UInt64
    }

    private enum CommitDecision {
        case readyForHandoff
        case stale
        case wait(DispatchSemaphore)
        case failed(Error)
    }

    private let admissionQueue = DispatchQueue(label: "com.doublesymmetry.trackplayer.playback-backend.admission")
    private let swapQueue = DispatchQueue(label: "com.doublesymmetry.trackplayer.playback-backend.swap")
    private let cleanupDiagnosticQueue = DispatchQueue(
        label: "com.doublesymmetry.trackplayer.playback-backend.cleanup-diagnostic"
    )
    private let factory: PlaybackBackendFactory
    private let authority: PlaybackBackendAuthority
    private let onCleanupDiagnostic: (PlaybackBackendCleanupDiagnostic) -> Void
    private let backendLock = NSLock()
    private var backend: PlaybackBackend
    private var nextOperationID = 0
    private var commandVersion: UInt64 = 0
    private var activeCommandLeases = 0
    private var leaseDrainWaiters: [DispatchSemaphore] = []
    private var physicalHandoffActive = false
    private var pendingCommandAdmissions: [() -> Void] = []

    init(
        initial: PlaybackBackend,
        factory: PlaybackBackendFactory,
        authority: PlaybackBackendAuthority = PlaybackBackendAuthority(),
        onCleanupDiagnostic: @escaping (PlaybackBackendCleanupDiagnostic) -> Void = { _ in }
    ) {
        backend = initial
        self.factory = factory
        self.authority = authority
        self.onCleanupDiagnostic = onCleanupDiagnostic
        authority.publish(initial)
        initial.activateInitialControlSurface()
    }

    var currentBackend: PlaybackBackend {
        backendLock.lock()
        let result = backend
        backendLock.unlock()
        return result
    }

    func withCurrentBackendAsync<Value>(
        timeout: TimeInterval = 30,
        _ operation: @escaping (
            PlaybackBackend,
            @escaping (Result<Value, Error>) -> Void
        ) throws -> Void,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        // Kept for source compatibility. A native command is never reported as
        // timed out while it can still mutate a backend; its lease ends only
        // when the native operation resolves or is explicitly cancelled.
        _ = timeout
        admissionQueue.async {
            self.admitCommand(operation, completion: completion)
        }
    }

    func withCurrentBackendRead<Value>(
        _ operation: @escaping (PlaybackBackend) throws -> Value,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        admissionQueue.async {
            self.admitRead(operation, completion: completion)
        }
    }

    func setPlaybackBackend(
        _ kind: PlaybackBackendKind,
        completion: @escaping (Result<PlaybackBackendTransactionResult, Error>) -> Void
    ) {
        swapQueue.async {
            self.nextOperationID += 1
            let operationID = self.nextOperationID

            do {
                let sameTarget: PlaybackBackend? = self.admissionQueue.sync {
                    let previous = self.backend
                    guard previous.kind == kind else { return nil }
                    return previous
                }
                if let sameTarget {
                    let snapshot = try self.captureSameTargetSnapshot(of: sameTarget)
                    completion(.success(PlaybackBackendTransactionResult(
                        backend: kind,
                        operationID: operationID,
                        snapshot: snapshot
                    )))
                    return
                }

                let previous = self.admissionQueue.sync { self.backend }
                for _ in 0..<Self.maximumPreparationAttempts {
                    let captured = try self.captureVersionedSnapshot(of: previous)
                    let replacement = self.factory.create(kind)
                    do {
                        try replacement.prepareSilently(captured.snapshot)
                        try replacement.restore(captured.snapshot)
                        try replacement.prepareActivation(captured.snapshot)
                    } catch {
                        self.cleanupUncommitted(replacement)
                        completion(.failure(error))
                        return
                    }

                    var admissionWaitCount = 0
                    while true {
                        let decision = self.admissionQueue.sync {
                            guard self.backend === previous else {
                                return CommitDecision.failed(self.busyError())
                            }
                            guard self.activeCommandLeases == 0 else {
                                let waiter = DispatchSemaphore(value: 0)
                                self.leaseDrainWaiters.append(waiter)
                                return CommitDecision.wait(waiter)
                            }
                            guard self.commandVersion == captured.version else {
                                return CommitDecision.stale
                            }

                            self.physicalHandoffActive = true
                            return CommitDecision.readyForHandoff
                        }

                        switch decision {
                        case .wait(let waiter):
                            admissionWaitCount += 1
                            waiter.wait()
                            if admissionWaitCount >= Self.maximumPreparationAttempts {
                                self.cleanupUncommitted(replacement)
                                completion(.failure(self.busyError()))
                                return
                            }
                            continue
                        case .stale:
                            self.cleanupUncommitted(replacement)
                        case .failed(let error):
                            self.cleanupUncommitted(replacement)
                            completion(.failure(error))
                            return
                        case .readyForHandoff:
                            var eventDeliverySuspended = false
                            var quiescenceStarted = false
                            var finalSnapshot: PlaybackBackendSnapshot?
                            do {
                                // From this point until finishPhysicalHandoff(), new commands
                                // are queued. Physical playback and its public event surface are
                                // therefore quarantined while the final snapshot is frozen.
                                eventDeliverySuspended = true
                                try previous.suspendEventDeliveryForHandoff()
                                quiescenceStarted = true
                                let quiescedSnapshot = try previous.beginHandoffQuiescence()
                                finalSnapshot = quiescedSnapshot

                                // Re-read the old backend's live queue and playback state. Both
                                // may have advanced naturally while the candidate was warming up.
                                try replacement.prepareSilently(quiescedSnapshot)
                                try replacement.restore(quiescedSnapshot)
                                try replacement.prepareActivation(quiescedSnapshot)
                                try previous.suspendControlSurface()
                                try previous.relinquishExclusiveControlSurfaceBeforeCommit()

                                let commitResult: Result<Void, Error> = self.admissionQueue.sync {
                                    guard self.physicalHandoffActive,
                                          self.backend === previous,
                                          self.activeCommandLeases == 0,
                                          self.commandVersion == captured.version else {
                                        return .failure(self.busyError())
                                    }
                                    replacement.commitQueue(quiescedSnapshot)
                                    self.backendLock.lock()
                                    self.backend = replacement
                                    self.backendLock.unlock()
                                    self.authority.publish(replacement)
                                    return .success(())
                                }
                                try commitResult.get()

                                replacement.activateAfterCommit(quiescedSnapshot)
                                self.finishPhysicalHandoff()
                                completion(.success(PlaybackBackendTransactionResult(
                                    backend: kind,
                                    operationID: operationID,
                                    snapshot: quiescedSnapshot
                                )))
                                self.disposeCommittedBackend(previous)
                                return
                            } catch {
                                var completionError = error
                                self.cleanupUncommitted(replacement)
                                let rollbackSnapshot = finalSnapshot ??
                                    (try? previous.snapshot()) ?? captured.snapshot
                                if quiescenceStarted {
                                    do {
                                        try previous.cancelHandoffQuiescence(rollbackSnapshot)
                                    } catch {
                                        completionError = self.rollbackFailedError()
                                    }
                                }
                                if eventDeliverySuspended {
                                    previous.resumeEventDeliveryAfterHandoff(rollbackSnapshot)
                                }
                                self.finishPhysicalHandoff()
                                completion(.failure(completionError))
                                return
                            }
                        }
                        break
                    }
                }

                completion(.failure(self.busyError()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func admitCommand<Value>(
        _ operation: @escaping (
            PlaybackBackend,
            @escaping (Result<Value, Error>) -> Void
        ) throws -> Void,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        if physicalHandoffActive {
            pendingCommandAdmissions.append { [weak self] in
                self?.admitCommand(operation, completion: completion)
            }
            return
        }

        let capturedBackend = backend
        commandVersion &+= 1
        activeCommandLeases += 1
        let commandCompletion = PlaybackBackendCommandCompletion<Value> { result in
            self.admissionQueue.async {
                self.activeCommandLeases -= 1
                if self.activeCommandLeases == 0 {
                    let waiters = self.leaseDrainWaiters
                    self.leaseDrainWaiters.removeAll()
                    waiters.forEach { $0.signal() }
                }
                completion(result)
            }
        }
        do {
            try operation(capturedBackend, commandCompletion.resolve)
        } catch {
            commandCompletion.resolve(.failure(error))
        }
    }

    private func admitRead<Value>(
        _ operation: @escaping (PlaybackBackend) throws -> Value,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        if physicalHandoffActive {
            pendingCommandAdmissions.append { [weak self] in
                self?.admitRead(operation, completion: completion)
            }
            return
        }

        let capturedBackend = backend
        activeCommandLeases += 1
        let result = Result { try operation(capturedBackend) }
        activeCommandLeases -= 1
        if activeCommandLeases == 0 {
            let waiters = leaseDrainWaiters
            leaseDrainWaiters.removeAll()
            waiters.forEach { $0.signal() }
        }
        completion(result)
    }

    private func finishPhysicalHandoff() {
        admissionQueue.sync {
            physicalHandoffActive = false
            let admissions = pendingCommandAdmissions
            pendingCommandAdmissions.removeAll()
            admissions.forEach { admission in
                admissionQueue.async(execute: admission)
            }
        }
    }

    private func captureSameTargetSnapshot(
        of expectedBackend: PlaybackBackend
    ) throws -> PlaybackBackendSnapshot {
        for _ in 0..<Self.maximumPreparationAttempts {
            let decision: (Result<PlaybackBackendSnapshot, Error>?, DispatchSemaphore?) = try admissionQueue.sync {
                guard backend === expectedBackend else {
                    return (.failure(busyError()), nil)
                }
                guard activeCommandLeases == 0 else {
                    let waiter = DispatchSemaphore(value: 0)
                    leaseDrainWaiters.append(waiter)
                    return (nil, waiter)
                }
                return (.success(try expectedBackend.snapshot()), nil)
            }
            if let result = decision.0 { return try result.get() }
            decision.1!.wait()
        }
        throw busyError()
    }

    private func captureVersionedSnapshot(
        of expectedBackend: PlaybackBackend
    ) throws -> VersionedSnapshot {
        for _ in 0..<Self.maximumPreparationAttempts {
            let decision: (Result<VersionedSnapshot, Error>?, DispatchSemaphore?) = try admissionQueue.sync {
                guard backend === expectedBackend else {
                    return (.failure(busyError()), nil)
                }
                try expectedBackend.settleActiveTransition()
                guard activeCommandLeases == 0 else {
                    let waiter = DispatchSemaphore(value: 0)
                    leaseDrainWaiters.append(waiter)
                    return (nil, waiter)
                }
                return (.success(VersionedSnapshot(
                    snapshot: try expectedBackend.snapshot(),
                    version: commandVersion
                )), nil)
            }

            if let capture = decision.0 {
                return try capture.get()
            }
            decision.1!.wait()
        }
        throw busyError()
    }

    private func cleanupUncommitted(_ replacement: PlaybackBackend) {
        try? replacement.stopAndMute()
        try? replacement.dispose()
    }

    private func disposeCommittedBackend(_ previous: PlaybackBackend) {
        let observer = onCleanupDiagnostic
        cleanupDiagnosticQueue.async {
            do {
                try previous.dispose()
            } catch {
                observer(.disposalFailed)
            }
        }
    }

    private func busyError() -> Error {
        return NSError(
            domain: "RNTrackPlayer.PlaybackBackend",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey: "The playback backend remained busy while preparing a replacement.",
                "code": "playback_backend_busy"
            ]
        )
    }

    private func rollbackFailedError() -> Error {
        return NSError(
            domain: "RNTrackPlayer.PlaybackBackend",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The previous playback backend could not be resumed after a failed handoff.",
                "code": "playback_backend_rollback_failed"
            ]
        )
    }
}

/// The code a load that gives up reports, on both backends and both platforms (Android:
/// `PREPARE_TIMEOUT_CODE`).
let standardPrepareTimeoutCode = "crossfade_prepare_timeout"

/// Where the standard player's current item is in its load, for `StandardLoadWatch`.
enum StandardLoadPhase: Equatable {
    /// Loading: no media yet, or waiting for it.
    case loading
    /// Has played or has media to play (ready, playing, ended; or paused or ready with media).
    case ready
    /// Stopped or with no item: whatever loads next is a new load.
    case idle
    /// The player failed (it reports its own error).
    case failed
}

/// The phase of a SwiftAudioEx state (`AVPlayerWrapperState.rawValue`) with the item's buffered
/// position: an item is ready once it plays or has media, as ExoPlayer's READY (an HLS item can be
/// "ready to play" before any segment arrived).
func standardLoadPhase(stateRawValue: String, bufferedPosition: Double) -> StandardLoadPhase {
    switch stateRawValue {
    case "failed": return .failed
    case "idle", "stopped": return .idle
    case "playing", "ended": return .ready
    case "ready", "paused": return bufferedPosition > 0 ? .ready : .loading
    default: return .loading
    }
}

/// What the standard player's load watch reads of the player, once per poll.
struct StandardLoadObservation {
    /// The current item's identity; nil with none, or when another owner waits (a seek, a
    /// candidate backend).
    let item: ObjectIdentifier?
    let phase: StandardLoadPhase
    /// Its progress: the load's bytes (`StandardLoadBytes`) and the buffered position; nil while
    /// the load has no progress signal (its AVPlayerItem does not exist yet: `standardLoadReadings`).
    let readings: [Double]?
    /// Another wait owns the player's loading now (a seek): not watched, but whether the item was
    /// ready is kept, so buffering once that wait ended is a rebuffer, not a load.
    var ownedElsewhere = false
}

/// The stall rule for the standard player's loads, as the crossfade engines apply it to theirs
/// and as Android's `StandardLoadWatch` (same rules): an item loading that has not been ready
/// since it was loaded (an item change, a load after a stop or an error: a retry) gives up after
/// `stallTimeoutMs` with no progress, or after `prepareTimeoutMs` in all. A rebuffer after ready
/// is not a load. Main thread.
final class StandardLoadWatch {
    /// A load in progress: its item, when it began (the first time the item was seen loading, even
    /// while a seek owned it) and its stage. As Android.
    struct Load: Equatable {
        let item: ObjectIdentifier
        let startedAt: TimeInterval
        var stage: Stage = .fresh

        /// Its progress was started (`startsLoad`; once per load).
        var progressStarted: Bool { return stage != .fresh }

        /// Its stall watch while it is watched.
        var watch: Watch? {
            if case let .watched(watch) = stage { return watch }
            return nil
        }

        /// A seek owns its loading: not watched, its progress kept.
        func disarmed() -> Load {
            guard case .watched = stage else { return self }
            var load = self
            load.stage = .disarmed
            return load
        }
    }

    /// Where a load stands (one explicit state; Android: `StandardLoadWatch.Stage`, the same moves):
    /// - `fresh`: seen loading, never watched (a seek owned it from its start): its progress not
    ///   started.
    /// - `watched(watch)`: watched, with its stall `Watch`; its progress started.
    /// - `disarmed`: watched before, a seek owns it now: no stall clock, its progress kept (once
    ///   the seek ends, it is watched again with its own total limit and a fresh stall clock).
    /// Moves: fresh -watched-> watched (its progress starts: `startsLoad`); watched -a seek owns
    /// it-> disarmed; disarmed -watched-> watched (its progress goes on); fresh and disarmed stay
    /// when a seek owns them.
    enum Stage: Equatable {
        case fresh
        case disarmed
        case watched(Watch)
    }

    /// A watched load's stage, as crossfade's prepare (IOSCrossfadeEngine: its playable stage has
    /// no readings, `StallWaitDriver` applies `capVerdict`):
    /// - `playable`: the load has no progress signal (nil readings: SwiftAudioEx has not created
    ///   the AVPlayerItem yet, it loads the asset's playable key, an HLS track's playlists). Only
    ///   the total limit ends it: a playlist slower than `stallTimeoutMs` does not fail the track
    ///   (Android counts playlist bytes as progress until the first segment is asked for).
    /// - `item`: readings arrived (the item exists): the stall rule, its clock restarted when the
    ///   item appeared (crossfade's `noteProgress` at the item's creation).
    /// Moves: watched -> playable or item (by its first readings); playable -readings-> item
    /// (progress noted); item -nil readings-> playable (the item went away: no signal again).
    enum Watch: Equatable {
        case playable(StallWatch)
        case item(StallWatch)

        var stall: StallWatch {
            switch self {
            case let .playable(watch), let .item(watch): return watch
            }
        }
    }

    /// Where the watch stands (one explicit state, the monorepo's state-machine form 3: a closed
    /// union moved only by `check` and `reset`; Android: `StandardLoadWatch.State`, same moves).
    ///
    /// - `idle(ready)`: no load. `ready` is the item ready since it was loaded (nil: none): its
    ///   buffering is a rebuffer, not a load.
    /// - `loading(ready, load)`: `load.item` loads (it is never `ready`, which a return to it would
    ///   find ready).
    ///
    /// Moves: no item or a failure -> idle(nil); owned elsewhere -> the load (if any) disarmed,
    /// and an item loading not ready since its load -> loading (the same load, else a new one from
    /// now); ready -> idle(item); idle phase -> idle(nil); loading the ready item -> idle(ready);
    /// loading another -> loading (its load, watched; a new one for a new item), and a verdict
    /// other than wait -> idle(ready); reset -> idle(nil).
    enum State: Equatable {
        case idle(ready: ObjectIdentifier?)
        case loading(ready: ObjectIdentifier?, load: Load)
    }

    private let stallTimeoutMs: () -> Int
    private let totalTimeoutMs: () -> Int
    private let now: () -> TimeInterval
    private(set) var state: State = .idle(ready: nil)
    /// The limits of the last load watched (what a give-up reports).
    private(set) var lastStallTimeoutMs = 0
    private(set) var lastTotalTimeoutMs = 0

    init(
        stallTimeoutMs: @escaping () -> Int,
        totalTimeoutMs: @escaping () -> Int,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.stallTimeoutMs = stallTimeoutMs
        self.totalTimeoutMs = totalTimeoutMs
        self.now = now
    }

    var isWatching: Bool { return watched != nil }

    private var ready: ObjectIdentifier? {
        switch state {
        case let .idle(ready), let .loading(ready, _): return ready
        }
    }

    private var load: Load? {
        if case let .loading(_, load) = state { return load }
        return nil
    }

    private var watched: Watch? { return load?.watch }

    /// Whether `check` would start a new load's progress with `observed` (its readings aside): an
    /// item loading, not ready since it was loaded and whose load has not started its progress
    /// yet, with no other owner (a load watched again after a seek goes on counting). The caller
    /// starts that load's progress (`StandardLoadBytes.startLoad`) before reading it, as
    /// Android's `onLoadStart`.
    func startsLoad(_ observed: StandardLoadObservation) -> Bool {
        guard let item = observed.item, observed.phase == .loading, !observed.ownedElsewhere else { return false }
        guard ready != item else { return false }
        if let load = load, load.item == item, load.progressStarted { return false }
        return true
    }

    /// Takes one observation: the verdict that ends a load the caller must give up, else nil.
    func check(_ observed: StandardLoadObservation) -> StallVerdict? {
        guard let item = observed.item, observed.phase != .failed else {
            state = .idle(ready: nil)
            return nil
        }
        if observed.ownedElsewhere {
            // A seek on an item not ready since it was loaded: its load goes on (and its total).
            if observed.phase == .loading, ready != item {
                state = .loading(ready: ready, load: loadOf(item).disarmed())
            } else if let load = load {
                state = .loading(ready: ready, load: load.disarmed())
            }
            return nil
        }
        switch observed.phase {
        case .ready:
            state = .idle(ready: item)
            return nil
        case .idle, .failed:
            state = .idle(ready: nil)
            return nil
        case .loading:
            break
        }
        if ready == item {
            state = .idle(ready: ready)
            return nil
        }
        var load = loadOf(item)
        var watch: Watch
        switch load.stage {
        case let .watched(current):
            watch = current
        case .fresh, .disarmed:
            var created = StallWatch(stallTimeoutMs: stallTimeoutMs(), totalTimeoutMs: totalTimeoutMs(), startedAt: load.startedAt)
            created.noteProgress(at: now())
            watch = .playable(created)
            lastStallTimeoutMs = created.stallTimeoutMs
            lastTotalTimeoutMs = created.totalTimeoutMs
        }
        let at = now()
        let verdict: StallVerdict
        switch (watch, observed.readings) {
        case let (.playable(stall), nil), let (.item(stall), nil):
            // No progress signal (no item yet, or no more): only the total limit.
            watch = .playable(stall)
            verdict = stall.capVerdict(at: at)
        case (.playable(var stall), let readings?):
            // The item appeared: a stage reached, the stall clock starts again from it.
            stall.noteProgress(at: at)
            verdict = stall.check(at: at, readings: readings)
            watch = .item(stall)
        case (.item(var stall), let readings?):
            verdict = stall.check(at: at, readings: readings)
            watch = .item(stall)
        }
        load.stage = .watched(watch)
        guard verdict != .wait else {
            state = .loading(ready: ready, load: load)
            return nil
        }
        state = .idle(ready: ready)
        return verdict
    }

    /// `item` is loading: the load in progress, or a new one from now.
    private func loadOf(_ item: ObjectIdentifier) -> Load {
        if let load = load, load.item == item { return load }
        return Load(item: item, startedAt: now())
    }

    /// When to check next, in milliseconds, while a load is watched (nil: none): at the moment the
    /// load would give up if nothing progresses, and every `standardLoadSampleIntervalMs` before
    /// it, to read the progress the player does not signal. Same rule as Android.
    func nextCheckInMs() -> Int? {
        guard let watch = watched else { return nil }
        let deadline: TimeInterval
        switch watch {
        // No progress signal: only the total limit ends it (the stall deadline would set a timer
        // at 0 ms in a loop); it is read every tenth of the stall timeout to see the item appear.
        case let .playable(stall): deadline = stall.capDeadline()
        case let .item(stall): deadline = stall.deadline()
        }
        let untilDeadline = max(0, Int(((deadline - now()) * 1000).rounded(.up)))
        return min(untilDeadline, standardLoadSampleIntervalMs(watch.stall.stallTimeoutMs))
    }

    /// Forgets the load in progress.
    func reset() {
        state = .idle(ready: nil)
    }
}

/// How often a watched load's progress is read between events, from its stall timeout: a tenth
/// of it. Same rule on Android (`standardLoadSampleIntervalMs`); no fixed interval.
func standardLoadSampleIntervalMs(_ stallTimeoutMs: Int) -> Int {
    return max(1, stallTimeoutMs / 10)
}

/// Runs a `StandardLoadWatch`: at each of the player's events (`poke`) and, only while a load is
/// watched, by one timer at the watch's next check. No load, no timer. Main thread. As Android's
/// StandardLoadDriver.
final class StandardLoadDriver {
    typealias Schedule = (_ delayMs: Int, _ work: @escaping () -> Void) -> DispatchWorkItem
    private let watch: StandardLoadWatch
    private let observe: () -> StandardLoadObservation
    private let giveUp: (StallVerdict) -> Void
    private let schedule: Schedule
    private var timer: DispatchWorkItem?
    private var stopped = false

    init(
        watch: StandardLoadWatch,
        observe: @escaping () -> StandardLoadObservation,
        giveUp: @escaping (StallVerdict) -> Void,
        schedule: @escaping Schedule = { delayMs, work in
            let item = DispatchWorkItem(block: work)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: item)
            return item
        }
    ) {
        self.watch = watch
        self.observe = observe
        self.giveUp = giveUp
        self.schedule = schedule
    }

    /// A timer is set (a load is watched).
    var isScheduled: Bool { return timer != nil }

    /// Checks now (an event, a command), then sets the timer while a load is watched.
    func poke() {
        timer?.cancel()
        timer = nil
        guard !stopped else { return }
        if let verdict = watch.check(observe()) { giveUp(verdict) }
        guard !stopped, let delay = watch.nextCheckInMs() else { return }
        timer = schedule(delay) { [weak self] in self?.poke() }
    }

    func stop() {
        stopped = true
        timer?.cancel()
        timer = nil
    }
}

/// The message of a standard load that gave up: the crossfade load's words without the engine
/// ("The track did not become ready (no progress for N ms)."), the same text on Android.
func standardLoadGiveUpMessage(_ verdict: StallVerdict, stallTimeoutMs: Int, totalTimeoutMs: Int) -> String {
    return "The track did not become ready (\(verdict.reason(stallTimeoutMs: stallTimeoutMs, totalTimeoutMs: totalTimeoutMs)))."
}

/// Which track is active around a load, and when the app is told, as the crossfade loadIndex
/// decides it (chosen alignment for both backends and both platforms; Android: `FailedLoadRule`,
/// same rules): a track becomes the active one once it loaded (ready), and only then is it
/// reported; while it loads and after its load fails (a give-up, a player error) the previous
/// track stays active (none when there was none) and the failed track is never reported. The next
/// play loads the previous track again or, when there was none, retries the track that failed.
/// Items are compared by identity. Shared scenarios: scripts/fixtures/failed-load-scenarios.json.
///
/// A standard player moves to an item before it loads (`moved`); the rule says when to report it.
/// The only move reported at once is the selection of a new queue's first track.
final class FailedLoadRule {
    /// A change of the active track to report: `to` (nil: none) from `from` (nil: none).
    struct Report: Equatable {
        let to: ObjectIdentifier?
        let from: ObjectIdentifier?
    }

    /// Where the player's own item stands (one explicit state, the monorepo's state-machine form
    /// 3: a closed union moved only by this class's events; Android: `FailedLoadRule.Phase`).
    ///
    /// - `selecting`: a new queue (or none); the player's first move is its selection, reported
    ///   at once. No item.
    /// - `loading(item)`: the player is on `item` (nil: none), not loaded since it moved there.
    /// - `loaded(item)`: `item` loaded: it is the active track (`active == item`).
    /// - `failed(item)`: `item`'s load failed (a give-up, a player error); the next play, seek or
    ///   stop acts on the active track again, else retries `item`. A move keeps it failed.
    ///
    /// Moves: selecting -moved(x)-> loading(x) (reported at once; x nil: stays); loading/loaded
    /// -moved(x)-> loaded(x) when x is the active track, else loading(x); failed -moved(x)->
    /// failed(x); any -ready-> loaded(item); loading/failed(not active) -failed-> failed(item);
    /// failed -play/command-> loaded/loading (the active track, else the failed one; command: a
    /// seek or stop, owner decision 2026-11-17); failed -skipped-> loading/loaded(item) (the
    /// player loads its own item); any -reset-> selecting; -adopted(x)-> loaded(x) (x nil: selecting);
    /// -activating(x)-> loaded(x) when x is the active track, else loading(x) (an idle activation:
    /// reported once it loaded); published, replaced and removed keep the kind and follow the item.
    enum Phase: Equatable {
        case selecting
        case loading(ObjectIdentifier?)
        case loaded(ObjectIdentifier?)
        case failed(ObjectIdentifier?)
    }

    /// The player's error, as the load sees it: `none`, or `reported` once a player error failed
    /// the load, until the player has no error any more (an edge: one failure per error, which
    /// outlives the moves, commands and a new queue that come while the player still has it).
    enum PlayerError: Equatable {
        case none
        case reported
    }

    private(set) var phase: Phase = .selecting
    private(set) var playerError: PlayerError = .none
    /// The active track: the last one that loaded.
    private(set) var active: ObjectIdentifier?
    /// The track the app was last told is active (nil: none).
    private(set) var reported: ObjectIdentifier?

    /// The player's item (nil: none, or a new queue's selection not made yet).
    private var current: ObjectIdentifier? {
        switch phase {
        case .selecting: return nil
        case let .loading(item), let .loaded(item), let .failed(item): return item
        }
    }

    /// The player is on `item`, not failed: loaded when it is the active track.
    private func following(_ item: ObjectIdentifier?) -> Phase {
        return item == active ? .loaded(item) : .loading(item)
    }

    /// The same kind of phase on `item` (a failed one stays failed).
    private func onItem(_ item: ObjectIdentifier?) -> Phase {
        switch phase {
        case .selecting: return .selecting
        case .failed: return .failed(item)
        case .loading, .loaded: return following(item)
        }
    }

    /// The player moved to `item`: whether to report it now (else once it loaded).
    func moved(_ item: ObjectIdentifier?) -> Bool {
        if phase == .selecting {
            // Nothing is reported in a new queue: a move to no item is no selection.
            if item == reported { return false }
            reported = item
            phase = following(item)
            return true
        }
        phase = onItem(item)
        return false
    }

    /// The current item is ready: it is the active track, reported when the app was not told.
    func ready() -> Report? {
        let item = current
        active = item
        phase = .loaded(item)
        return reportTrack(item)
    }

    /// The current item's load failed: the previous track stays active; a report only when the
    /// failed track had been reported (a selected first track): back to the active one.
    func failed() -> Report? {
        let item: ObjectIdentifier?
        switch phase {
        case let .loading(loading): item = loading
        case let .failed(failed):
            guard failed != active else { return nil }
            item = failed
        case .selecting, .loaded: return nil
        }
        phase = .failed(item)
        return reportTrack(active)
    }

    /// A play: the item to load first (the active one, else the failed one), or nil to play the current.
    func play() -> ObjectIdentifier? {
        guard case let .failed(failed) = phase else { return nil }
        let target = active ?? failed
        phase = following(target)
        return target
    }

    /// A seek or a stop acts on the active track, as crossfade's (owner decision, 2026-11-17: the
    /// one the app reads, getActiveTrack and its position): after a failed load the player goes
    /// back to the active track (the backend moves it there), else, with none, retries the failed
    /// one. Reported once it loads (no report now).
    func command() -> Report? {
        if case let .failed(failed) = phase { phase = following(active ?? failed) }
        return nil
    }

    /// A skip, next, previous or load (and a backend restore): the player loads its own item, a
    /// failed one it stays on again (a skip to the track that failed); a move to another item
    /// follows (`moved`).
    func skipped() {
        if case let .failed(failed) = phase { phase = following(failed) }
    }

    /// The queue was replaced or cleared: its first track is a new selection.
    func reset() {
        phase = .selecting
        active = nil
        reported = nil
    }

    /// `item` left the queue: when it was the reported (or active) track, there is none any more,
    /// reported at once (the next track is reported once it loaded).
    func removed(_ item: ObjectIdentifier?) -> Report? {
        guard let item = item else { return nil }
        if active == item { active = nil }
        phase = onItem(current == item ? nil : current)
        return reported == item ? reportTrack(nil) : nil
    }

    /// A play, retry, skip, next or load with no active track (the logical idle) activates the
    /// player's `item`: it loads, and is reported once it loaded, as crossfade's play with no
    /// active track (never a track that fails to load); not a new queue's selection (reported at
    /// once). Android: the same `activating`.
    func activating(_ item: ObjectIdentifier?) {
        phase = following(item)
    }

    /// The app was told about `item` another way (a logical idle activation with no load watch).
    func published(_ item: ObjectIdentifier?) {
        reported = item
        if case .failed = phase { phase = .failed(item) } else { phase = following(item) }
    }

    /// The player is on `item`, loaded and known to the app (a backend switch restored it).
    func adopted(_ item: ObjectIdentifier?) {
        active = item
        reported = item
        phase = item == nil ? .selecting : .loaded(item)
    }

    /// `old` was replaced by `new` for the same track (new metadata): it keeps its place. (The
    /// iOS backends update a Track's metadata in place, same identity: kept for the shared rule.)
    func replaced(_ old: ObjectIdentifier?, with new: ObjectIdentifier?) {
        if active == old { active = new }
        if reported == old { reported = new }
        let item = current
        phase = onItem(item == old ? new : item)
    }

    /// The player is on an item other than the one reported: report `reported`'s index instead.
    func isPending(_ item: ObjectIdentifier?) -> Bool {
        return item != reported
    }

    /// The player reports a failure: true the first time (the caller fails the load), false while it lasts.
    func playerErrorSeen() -> Bool {
        if playerError == .reported { return false }
        playerError = .reported
        return true
    }

    /// The player has no failure: true when one had failed the load (it is over now).
    func playerErrorGone() -> Bool {
        let had = playerError == .reported
        playerError = .none
        return had
    }

    private func reportTrack(_ to: ObjectIdentifier?) -> Report? {
        guard to != reported else { return nil }
        let from = reported
        reported = to
        return Report(to: to, from: from)
    }
}

/// A track's progress as the app reads it (position, duration, buffered), in seconds.
struct TrackProgress: Equatable {
    let position: Double
    let duration: Double
    let buffered: Double

    static let none = TrackProgress(position: 0, duration: 0, buffered: 0)
}

/// The progress every reader sees (getters, progress events): the reported track's, as the
/// active track itself (monorepo rule 13: readers agree with getActiveTrack; Android: the same
/// `ReportedTrackProgress`). While the player is on the reported track, its live values, kept;
/// while another track loads (or failed to load), the reported track's as the player left it (its
/// last position, its duration, what it had buffered); with no reported track, none (zeros).
final class ReportedTrackProgress {
    // Read by the module's read queue and the player's event queue too (getters, progress events).
    private let lock = NSLock()
    private var item: ObjectIdentifier?
    private var last = TrackProgress.none

    /// What the app reads now: `live` when the player is on `reported`, else what it had.
    func read(reported: ObjectIdentifier?, playerItem: ObjectIdentifier?, live: TrackProgress) -> TrackProgress {
        lock.lock()
        defer { lock.unlock() }
        if playerItem == reported {
            item = reported
            last = live
            return live
        }
        return reported != nil && item == reported ? last : .none
    }

    /// The player left `item` at `position` (its item change): that track's last position.
    func left(_ item: ObjectIdentifier?, position: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let item = item, item == self.item else { return }
        last = TrackProgress(position: position, duration: last.duration, buffered: max(last.buffered, position))
    }

    /// `old` was replaced by `new` for the same track (new metadata): it keeps what it had.
    func replaced(_ old: ObjectIdentifier?, with new: ObjectIdentifier?) {
        lock.lock()
        defer { lock.unlock() }
        if old != nil, item == old { item = new }
    }
}

/// What the lock screen (Android: the notification) shows of the standard player: the reported
/// track, as getActiveTrack (monorepo rule 13; Android: the same `ReportedNowPlaying`). While
/// another track loads (or failed to load) it is held on the reported one, shown again at every
/// move of the player (which shows its own item); once the player is on the reported track again
/// (it loaded, or play reloads it), or none is reported, it is released. No reported track: the
/// player's own. Main.
final class ReportedNowPlaying {
    /// Show `item` (nil: the player's own item); `held`: the player's own updates are held.
    struct Change: Equatable {
        let item: ObjectIdentifier?
        let held: Bool
    }

    /// What is shown (one explicit state, the monorepo's state-machine form 3, moved only by
    /// `follow`; Android: `ReportedNowPlaying.State`, same moves):
    /// - `released`: the player's own updates go through (it is on the reported track, or none
    ///   is reported).
    /// - `held(item, on)`: `item` (the reported track) is shown while the player is on `on` (nil:
    ///   no item); the player's own updates are held.
    ///
    /// Moves: any -(reported r, player p != r)-> held(r, p) (a change, unless already held(r, p));
    /// held -(none reported, or the player on it)-> released (a change); released stays.
    enum State: Equatable {
        case released
        case held(item: ObjectIdentifier, on: ObjectIdentifier?)
    }

    private(set) var state: State = .released

    var isHeld: Bool {
        if case .held = state { return true }
        return false
    }

    /// The reported track and the player's item now: what to show, nil when nothing changes.
    func follow(reported: ObjectIdentifier?, playerItem: ObjectIdentifier?) -> Change? {
        if let reported = reported, playerItem != reported {
            let next = State.held(item: reported, on: playerItem)
            if state == next { return nil }
            state = next
            return Change(item: reported, held: true)
        }
        guard isHeld else { return nil }
        state = .released
        return Change(item: reported, held: false)
    }
}

/// A standard load or seek given up: the error the player is in until the next command (nil once
/// a command acted), and, for a seek, its target, which stays the position (SwiftAudioEx's stop
/// resets its own) until the track loads again there. As a failed crossfade seek and Android's
/// standard player (ExoPlayer keeps the position at its stop).
struct StandardGiveUp<Failure> {
    let failure: Failure?
    let keptPosition: Double?

    /// The position to report: a failed seek's target, else the player's own.
    func position(live: Double) -> Double {
        return keptPosition ?? live
    }
}

/// The track a play loads after a failed load (crossfade, both platforms): the active track when
/// there is one; with none (the first load failed), the track that failed, retried; nil when
/// neither is in the queue. The standard backends follow the same rule (FailedLoadRule.play).
func indexToPlayAfterFailedLoad(currentIndex: Int, failedIndex: Int?, count: Int) -> Int? {
    if (0..<count).contains(currentIndex) { return currentIndex }
    guard let failedIndex = failedIndex, (0..<count).contains(failedIndex) else { return nil }
    return failedIndex
}

/// Whether a standard native seek that ended stops loading: one that ended unfinished on its
/// own track and was the latest (no newer seek replaced it: AVPlayer ends a replaced seek
/// unfinished, which is not a failure), as `settleCrossfadeSeek` on the crossfade path, on an
/// item AVPlayer can seek in (`standardSeekEndCompletes`: on one it cannot, an unfinished seek
/// completes where the player is). A seek that gives up (`standard_seek_timeout`) stops loading
/// too; a player failure has stopped it.
func standardSeekEndStopsLoading(didFinish: Bool, sameTrack: Bool, isLatest: Bool, seekable: Bool) -> Bool {
    return !didFinish && seekable && sameTrack && isLatest
}

/// Whether a standard native seek that ended resolves: one that finished on its own track, or
/// one AVPlayer ended unfinished on an item it cannot seek in (no seekable range: a stream with
/// no length, as a raw ADTS radio stream; AVPlayer then seeks only within the data it loaded and
/// otherwise stays where it is, measured with AVFoundation on macOS). Such a seek completes where
/// the player is, as Android's completes where ExoPlayer lands (its start) on an item ExoPlayer
/// cannot seek in. Any other unfinished end rejects (`standard_seek_cancelled`).
func standardSeekEndCompletes(didFinish: Bool, sameTrack: Bool, seekable: Bool) -> Bool {
    return sameTrack && (didFinish || !seekable)
}

/// What a standard seek reads of SwiftAudioEx's AVPlayerItem (`standardPlayerItem`).
struct StandardSeekItem: Equatable {
    /// The item is ready to play: SwiftAudioEx then seeks AVPlayer at once, which always calls
    /// back (without an item it defers the seek and may never call back).
    let ready: Bool
    /// AVPlayer can seek in the item (it has a seekable range); true when the item cannot be
    /// read (no item yet, another SwiftAudioEx layout): the seek's usual rules apply.
    let seekable: Bool
}

func standardSeekItem(_ lookup: StandardPlayerItemLookup) -> StandardSeekItem {
    guard case let .item(item?) = lookup else { return StandardSeekItem(ready: false, seekable: true) }
    return StandardSeekItem(ready: item.status == .readyToPlay, seekable: !item.seekableTimeRanges.isEmpty)
}

/// Whether a queued standard seek is issued now: once its item has a duration, or, for one with
/// none (a stream with no length: SwiftAudioEx's duration is 0 for it, for good), once its item
/// is ready to play. Before, such a seek waited for a duration that never came and rejected at
/// `standardSeekTimeoutMs`.
func standardSeekCanBeIssued(duration: Double, item: StandardSeekItem) -> Bool {
    return duration > 0 || item.ready
}

/// The code a standard command rejects with when the player fails its track's load, as a
/// crossfade load whose engine fails (both platforms).
let standardLoadErrorCode = "crossfade_engine_error"
/// The message of a standard load that failed with no message of its own (Android: the same).
let standardLoadFailedMessage = "The track failed to load."
/// The message of a standard command's wait that a newer command ended (Android: the same).
let standardCommandLoadCancelledMessage = "A newer command replaced this one before its track loaded."

/// How a standard command's wait for its track's load ended.
enum StandardCommandLoadOutcome: Equatable {
    case loaded
    case failed(code: String, message: String)
    case cancelled
}

/// The standard player's commands that load a track (skip, next, previous, load) end as the
/// crossfade path's do: once the track loaded and is the active one (`FailedLoadRule`), or with
/// the load's failure, rejected with its code (a give-up: `crossfade_prepare_timeout`; a player
/// error: `crossfade_engine_error`). A newer command that loads, seeks or stops ends the older
/// wait with `cancelled`. A failure a command waits for is reported by its rejection only, not
/// also as a playback error (a load no command waits for, a natural advance, reports a playback
/// error). Same rule on Android (StandardCommandLoad.kt). Items are compared by identity. Main.
final class StandardCommandLoad {
    /// One command's wait for `target`'s load.
    final class Wait {
        let target: ObjectIdentifier
        fileprivate let settle: (StandardCommandLoadOutcome) -> Void

        fileprivate init(target: ObjectIdentifier, settle: @escaping (StandardCommandLoadOutcome) -> Void) {
            self.target = target
            self.settle = settle
        }
    }

    private var wait: Wait?
    /// The item whose failure a command's rejection reported (no playback error for it).
    private var failureReportedByCommand: ObjectIdentifier?

    /// A command waits for a load.
    var isWaiting: Bool { return wait != nil }

    /// A command waits for `target`'s load: settled at once when `target` is already the loaded
    /// track the app was told of (`FailedLoadRule`'s `active` and `reported`), else by
    /// `ruleSettled`, `failed` or `cancel`. An older wait ends cancelled. Returns the wait, nil
    /// when settled at once.
    @discardableResult
    func begin(
        target: ObjectIdentifier,
        active: ObjectIdentifier?,
        reported: ObjectIdentifier?,
        settle: @escaping (StandardCommandLoadOutcome) -> Void
    ) -> Wait? {
        cancel()
        failureReportedByCommand = nil
        if active == target && reported == target {
            settle(.loaded)
            return nil
        }
        let created = Wait(target: target, settle: settle)
        wait = created
        return created
    }

    /// `FailedLoadRule` after a ready item: the wait for the track that loaded ends once it is
    /// the active track and the app was told of it (a new queue's first track was reported at its
    /// selection: it ends at its load all the same).
    func ruleSettled(active: ObjectIdentifier?, reported: ObjectIdentifier?) {
        guard let current = wait, let active = active, active == reported, current.target == active else { return }
        wait = nil
        current.settle(.loaded)
    }

    /// Whether a command waits for `item`'s load (its failure is then that command's to report).
    func waits(for item: ObjectIdentifier?) -> Bool {
        return item != nil && wait?.target == item
    }

    /// `item`'s load failed: its wait ends rejected with `code`. `reportedByPlayer`: the player
    /// also sends this failure as its own error event (a player error, not a give-up, whose report
    /// the backend decides at once), which the rejection replaces. Returns whether one waited.
    @discardableResult
    func failed(_ item: ObjectIdentifier?, code: String, message: String, reportedByPlayer: Bool) -> Bool {
        guard let current = wait, current.target == item else { return false }
        wait = nil
        if reportedByPlayer { failureReportedByCommand = item }
        current.settle(.failed(code: code, message: message))
        return true
    }

    /// A newer command that loads, seeks, pauses or stops: the wait in progress ends cancelled.
    /// Returns whether one was waiting (`standardCancelledLoad`).
    @discardableResult
    func cancel() -> Bool {
        guard let current = wait else { return false }
        wait = nil
        current.settle(.cancelled)
        return true
    }

    /// Whether the player's error on `item` is a command's to report (by its rejection): one
    /// waits for its load, or rejected with its failure.
    func reportsFailure(of item: ObjectIdentifier?) -> Bool {
        guard let item = item else { return false }
        return wait?.target == item || failureReportedByCommand == item
    }

    /// The player is no longer in that error, or a command loads again (play, retry): its later
    /// errors are reported again.
    func failureCleared() {
        failureReportedByCommand = nil
    }
}

/// Where a seek, pause or stop leaves the player when a load is pending, as crossfade's operation
/// cancelled while it loads: the cancelled command does not take effect, and its track is never
/// reported. A seek or stop (`actsOnReportedTrack`) acts on the reported track whenever the player
/// is on another one (a skip or load waiting, a natural advance loading, a skip that failed: owner
/// decision, 2026-11-17, LOAD-06); a pause only when it cancelled a command's wait
/// (`StandardCommandLoad.cancel` returned true: a skip, next, previous or load whose track was
/// still loading). Android: the same rule (`standardCancelledLoad`, `StandardCancelledLoad`).
enum StandardCancelledLoad: Equatable {
    /// Nothing pending, or the player is on the reported track (none reported: a seek retries the
    /// failed track): it stays.
    case stays
    /// The player goes back to the reported track, paused (the seek acts there).
    case returnsTo(ObjectIdentifier)
    /// No track is reported (the first load failed, or the reported one left the queue): the
    /// cancelled load stops and the player has no active track (the logical idle, as crossfade's
    /// active index -1): nothing loads or is reported until a play, skip or load selects a track
    /// again (a play from idle starts the first track, as crossfade's).
    case stopsInIdle
}

/// What a seek, pause or stop leaves (`StandardCancelledLoad`); `cancelledWait`: it cancelled a
/// command's wait; `reported`: the track the app was told is active; `actsOnReportedTrack`: a
/// seek or stop (owner decision, 2026-11-17), not a pause.
func standardCancelledLoad(cancelledWait: Bool, playerItem: ObjectIdentifier?, reported: ObjectIdentifier?, actsOnReportedTrack: Bool = false) -> StandardCancelledLoad {
    guard let reported = reported else { return cancelledWait ? .stopsInIdle : .stays }
    if reported == playerItem { return .stays }
    return cancelledWait || actsOnReportedTrack ? .returnsTo(reported) : .stays
}

/// The track a play, load or retry from the logical idle (no active track) selects first: the
/// queue's first one when the player is elsewhere, as Android (selectFirstPhysicalItemIfNeeded)
/// and crossfade's play with no active track. Nil: the player is on it, or the queue is empty.
func standardFirstTrackToSelect(currentIndex: Int, count: Int) -> Int? {
    return count > 0 && currentIndex != 0 ? 0 : nil
}

/// Whether a command's wait must start its track's load: the track is not the loaded one and the
/// player is not loading (stopped by a give-up, failed, or idle). Else nothing would end the wait.
/// Android: the same rule (`standardCommandLoadMustStart`).
func standardCommandLoadMustStart(targetLoaded: Bool, stateRawValue: String) -> Bool {
    return !targetLoaded && ["idle", "stopped", "failed"].contains(stateRawValue)
}

/// A playback error as the app receives it: its message and code.
struct IOSPlaybackErrorSnapshot: Equatable {
    let message: String?
    let code: String?

    var dictionary: Dictionary<String, Any> {
        var body: Dictionary<String, Any> = [:]
        if let message = message {
            body["message"] = message
        }
        if let code = code {
            body["code"] = code
        }
        return body
    }
}

/// What the app receives for a standard load or seek given up, the same events as Android's
/// standard player: the error state with the failure, then a playback error with its code and
/// message when no command reports it (a load no command waits for: a natural advance, a play).
/// With no failure, the stop that ended a give-up's error: the stopped state (Android: KotlinAudio's
/// stop emits it; SwiftAudioEx, already stopped by the give-up, emits nothing).
struct StandardGiveUpReport {
    let failure: IOSPlaybackErrorSnapshot?
    let reportsPlaybackError: Bool

    /// The events in order, by name (`EventType`'s raw value) with their body.
    var events: [(name: String, body: [String: Any])] {
        guard let failure = failure else {
            return [(name: "playback-state", body: ["state": "stopped"])]
        }
        var events: [(name: String, body: [String: Any])] = [
            (name: "playback-state", body: ["state": "error", "error": failure.dictionary])
        ]
        if reportsPlaybackError {
            events.append((name: "playback-error", body: failure.dictionary))
        }
        return events
    }
}

/// The standard player's give-ups, a load or a seek with no progress for `stallTimeoutMs` or over
/// its limit, as the crossfade path and Android's standard player: the player stops loading (the
/// caller's `stop`, given the report to emit) and is in error with the failure until the next
/// command (`clear`); a failed seek keeps its target as the position. A load a command waits for
/// (skip, next, previous, load) is reported by that command's rejection with the same code and
/// message, not also as a playback error. Main.
final class StandardGiveUps {
    private var state: StandardGiveUp<IOSPlaybackErrorSnapshot>?

    /// The failure the player is in (nil: none).
    var failure: IOSPlaybackErrorSnapshot? { return state?.failure }

    /// The position to report: a failed seek's target, else the player's own.
    func position(live: Double) -> Double {
        return state?.position(live: live) ?? live
    }

    /// The load of `item` gave up with `verdict`: `stop` ends it (and emits the report), then a
    /// command waiting for it ends rejected with `crossfade_prepare_timeout`.
    func loadGaveUp(
        _ verdict: StallVerdict,
        stallTimeoutMs: Int,
        totalTimeoutMs: Int,
        item: ObjectIdentifier?,
        commandLoads: StandardCommandLoad,
        stop: (StandardGiveUpReport) -> Void
    ) {
        let message = standardLoadGiveUpMessage(verdict, stallTimeoutMs: stallTimeoutMs, totalTimeoutMs: totalTimeoutMs)
        let failure = IOSPlaybackErrorSnapshot(message: message, code: standardPrepareTimeoutCode)
        state = StandardGiveUp(failure: failure, keptPosition: nil)
        stop(StandardGiveUpReport(failure: failure, reportsPlaybackError: !commandLoads.waits(for: item)))
        commandLoads.failed(item, code: standardPrepareTimeoutCode, message: message, reportedByPlayer: false)
    }

    /// A seek to `keptPosition` gave up with `failure`: its rejection is the report (no playback
    /// error); its target stays the position.
    func seekGaveUp(_ failure: IOSPlaybackErrorSnapshot, keptPosition: Double, stop: (StandardGiveUpReport) -> Void) {
        state = StandardGiveUp(failure: failure, keptPosition: keptPosition)
        stop(StandardGiveUpReport(failure: failure, reportsPlaybackError: false))
    }

    /// A command: the player is no longer in that error. Returns the position a failed seek kept,
    /// for a play or retry to load the track there.
    @discardableResult
    func clear() -> Double? {
        let kept = state?.keptPosition
        state = nil
        return kept
    }

    /// Out of the error state, a failed seek's target stays the position until the track loads.
    func keep(_ kept: Double?) {
        state = kept.map { StandardGiveUp(failure: nil, keptPosition: $0) }
    }

    /// A stop, as Android's standard player: it ends the error (a failed seek's target stays the
    /// position until the track loads) and the app is told the player is stopped. Returns that
    /// report when the player was in error and SwiftAudioEx emits nothing itself (`playerStopped`:
    /// it is already stopped, as after a give-up); else nil. A pause (`setPlayWhenReady(false)`)
    /// is no command on the error: it stays, as Android's (nothing to call here).
    func stopped(playerStopped: Bool) -> StandardGiveUpReport? {
        let wasInError = failure != nil
        keep(clear())
        guard wasInError, playerStopped else { return nil }
        return StandardGiveUpReport(failure: nil, reportsPlaybackError: false)
    }
}

/// What `StandardLoadCoordinator` asks of the standard player: `StandardPlaybackBackend` over
/// SwiftAudioEx (each a one-line adapter, pinned by verify-ios-crossfade-contracts), a fake in
/// tests. Main.
protocol StandardLoadPlayer: AnyObject {
    /// The player's current item (nil: none).
    var currentLoadItem: ObjectIdentifier? { get }
    /// SwiftAudioEx's state (`AVPlayerWrapperState.rawValue`).
    var loadStateRawValue: String { get }
    /// The player's own error message, when it failed.
    var loadErrorMessage: String? { get }
    /// Loads the current item again from its start (SwiftAudioEx's reload).
    func reloadForCommand()
    /// Looks at the load now (`StandardLoadDriver.poke`).
    func checkLoad()
    /// Stops loading after a give-up: the module's request becomes "paused" and SwiftAudioEx stops
    /// (its item leaves the AVPlayer, which stops requesting media).
    func stopLoading(log: String)
    /// Emits a give-up's events (`StandardGiveUpReport.events`).
    func emitGiveUp(_ report: StandardGiveUpReport)
    /// Tells the app of a change of the active track (`FailedLoadRule.Report`).
    func reportActiveTrack(_ change: FailedLoadRule.Report)
    /// A load failed while `reported` stays the active track: the lock screen shows it again.
    func showAfterFailedLoad(_ reported: ObjectIdentifier?)
    /// The lock screen follows the reported track (`ReportedNowPlaying`).
    func followNowPlaying()
    /// Logs a failed load (`active`: the active track then).
    func logFailedLoad(active: ObjectIdentifier?)
    /// The position the app reads: the reported track's (`ReportedTrackProgress`, rule 13).
    var reportedPosition: Double { get }
    /// No track is active (the logical idle).
    var isIdle: Bool { get }
    /// SwiftAudioEx is stopped (its item unloaded).
    var isPlayerStopped: Bool { get }
    /// The module's playback request (`RequestedPlayback`): what an ended interruption resumes.
    func requestPlayback(_ playing: Bool)
    /// Whether playback is requested now (`RequestedPlayback`).
    var playbackRequested: Bool { get }
    /// Plays, requested (SwiftAudioEx's play).
    func resumePlayback()
    /// Ends the seeks in progress (`standard_seek_cancelled`).
    func cancelSeeks()
    /// Moves the player to `item`, paused (SwiftAudioEx's jumpToItem); false when it left the queue.
    func jumpPaused(to item: ObjectIdentifier) -> Bool
    /// SwiftAudioEx's seek (applied once the item loaded).
    func seekPlayer(to position: Double)
    /// SwiftAudioEx's pause.
    func pausePlayer()
    /// SwiftAudioEx's stop (its item leaves the AVPlayer, which stops requesting media).
    func stopPlayer()
    /// No active track any more, the queue kept (the logical idle).
    func enterIdle()
}

/// The standard player's load sequences (StandardPlaybackBackend runs them; this file is the
/// one the tests execute, so deleting a step breaks a test, not only a text pin): which track is
/// active (`failedLoads`), a command's wait for its track's load (`commandLoads`), the give-ups
/// (`giveUps`) and what each event does with them, in order. As the crossfade path and Android's
/// standard player (KotlinAudioPlaybackBackend). Main.
final class StandardLoadCoordinator {
    let failedLoads = FailedLoadRule()
    let commandLoads = StandardCommandLoad()
    let giveUps = StandardGiveUps()
    private weak var player: StandardLoadPlayer?
    /// The player's loads are watched (a load watch exists): a command waits for its load.
    private let watched: Bool
    private(set) var disposed = false
    /// Whether playback was requested when the last give-up stopped the player (it stops the
    /// request with SwiftAudioEx); a pause or stop ends it.
    private var playRequestedAtGiveUp = false
    /// A seek that went back to the active track after a failed load plays once it is done, as
    /// playback was requested (`beginSeek`, `seekFinished`).
    private(set) var resumesAfterSeek = false

    init(player: StandardLoadPlayer, watched: Bool) {
        self.player = player
        self.watched = watched
    }

    /// The error a give-up left the player in, until the next command (nil: none).
    var hostFailure: IOSPlaybackErrorSnapshot? { return giveUps.failure }

    /// The backend is disposed: a waiting command ends cancelled, no more give-ups.
    func dispose() {
        disposed = true
        commandLoads.cancel()
    }

    /// Whether SwiftAudioEx's own state event is emitted: not its `stopped` after a give-up (the
    /// give-up stopped it; the player is in error, emitted with the give-up), as Android, where
    /// the give-up's ERROR state is the last state. A stop ends that error first
    /// (`StandardGiveUps.stopped`): its own `stopped` is emitted.
    func emitsPlayerState(_ stateRawValue: String) -> Bool {
        // With no active track (the logical idle) the player only loads for a queue change it
        // stopped at once (`queueChanged`): no loading for the app, as Android, which loads nothing.
        return !(stateRawValue == "stopped" && giveUps.failure != nil) && !(stateRawValue == "loading" && (player?.isIdle ?? false))
    }

    /// The player moved to `item` (SwiftAudioEx's item change): whether to report it now
    /// (`FailedLoadRule.moved`). With no active track (the logical idle: a queue change) nothing
    /// is reported and the rule does not move; the command that activates a track does
    /// (`idleActivation`), as Android, whose load watch does not look at the player in the idle.
    func itemMoved(_ item: ObjectIdentifier?) -> Bool {
        guard !(player?.isIdle ?? false) else { return false }
        return failedLoads.moved(item)
    }

    /// After a queue change (add, move, remove, a new queue): with no active track (the logical
    /// idle) the player loads nothing and stays stopped, as crossfade's queue change with no
    /// active track and Android (SwiftAudioEx loads a new queue's first item, or the next one when
    /// the current item left: stopped at once). Its state is the player's (stopped).
    func queueChanged() {
        guard let player = player, player.isIdle, player.loadStateRawValue == "loading" else { return }
        player.stopPlayer()
        player.enterIdle()
    }

    /// A play, retry, skip, next or load with no active track (the logical idle) activated the
    /// player's `item`: it loads and is reported once it loaded (`FailedLoadRule.activating`), as
    /// crossfade's play with no active track and Android, never a track that fails to load.
    /// Returns whether to tell the app now: only with no load watch (nothing tells when it
    /// loaded), the app told of it at once (`FailedLoadRule.published`).
    func idleActivation(_ item: ObjectIdentifier?) -> Bool {
        guard watched else {
            failedLoads.published(item)
            return true
        }
        failedLoads.activating(item)
        return false
    }

    /// What the load watch saw (`StandardLoadObservation`), fed to `failedLoads` and
    /// `commandLoads`: a player failure fails the load (once per error) and rejects a waiting
    /// command with the player's error; a ready item is the active track (reported when the app
    /// was not told) and ends a command waiting for it.
    func followLoad(_ observed: StandardLoadObservation) {
        guard observed.item != nil else { return }
        if observed.phase == .failed {
            if failedLoads.playerErrorSeen() {
                failLoadedTrack()
                // A command waiting for this load rejects with the player's error, as a crossfade
                // load that fails (crossfade_engine_error).
                commandLoads.failed(
                    observed.item,
                    code: standardLoadErrorCode,
                    message: player?.loadErrorMessage ?? standardLoadFailedMessage,
                    reportedByPlayer: true
                )
            }
            return
        }
        if failedLoads.playerErrorGone() { commandLoads.failureCleared() }
        if observed.ownedElsewhere { return }
        if observed.phase == .ready {
            if let change = failedLoads.ready() { player?.reportActiveTrack(change) }
            commandLoads.ruleSettled(active: failedLoads.active, reported: failedLoads.reported)
        }
    }

    /// Waits for the load a command started (skip, next, previous, load) on the player's current
    /// item, as the crossfade path: `loaded` once it loaded and is the active track; `failed`
    /// with the load's failure (crossfade_prepare_timeout, crossfade_engine_error); `cancelled`
    /// when a newer command replaced it. Loads not watched (no load watch), disposed, or no item:
    /// `loaded` at once.
    func waitForCommandLoad(_ completion: @escaping (StandardCommandLoadOutcome) -> Void) {
        guard watched, !disposed, let player = player, let target = player.currentLoadItem else {
            completion(.loaded)
            return
        }
        let wait = commandLoads.begin(target: target, active: failedLoads.active, reported: failedLoads.reported, settle: completion)
        // Its track must load: after a give-up or a player error on it (a skip to the same
        // track does not jump), the player stands still.
        if wait != nil, standardCommandLoadMustStart(targetLoaded: false, stateRawValue: player.loadStateRawValue) {
            player.reloadForCommand()
        }
        // The load is looked at now (the player's events of the command may have come first).
        player.checkLoad()
    }

    /// The load watch gave up the current item's load (`verdict`, with the limits it used): a load
    /// no command waits for is reported as a playback error, one a command waits for by its
    /// rejection (StandardGiveUps).
    func giveUpLoad(_ verdict: StallVerdict, stallTimeoutMs: Int, totalTimeoutMs: Int) {
        let reason = verdict.reason(stallTimeoutMs: stallTimeoutMs, totalTimeoutMs: totalTimeoutMs)
        giveUps.loadGaveUp(
            verdict,
            stallTimeoutMs: stallTimeoutMs,
            totalTimeoutMs: totalTimeoutMs,
            item: player?.currentLoadItem,
            commandLoads: commandLoads
        ) { report in
            stopAfterGiveUp(log: "load \(reason)", report: report)
        }
    }

    /// A seek's wait gave up (`message`): as a crossfade seek that gives up and as Android, the
    /// player stops loading and is in error (the rejection is the report: no playback error), and
    /// its track failed again (`stopAfterGiveUp`), when the player is still on its track
    /// (`track`), the seek issued or still waiting for its item (its track's playlists never
    /// answered: the play then loads the active track); a seek for a track the player left only
    /// rejects.
    func seekTimedOut(issued: Bool, track: ObjectIdentifier, message: String, keptPosition: Double) {
        guard player?.currentLoadItem == track else { return }
        giveUps.seekGaveUp(
            IOSPlaybackErrorSnapshot(message: message, code: "standard_seek_timeout"),
            keptPosition: keptPosition
        ) { report in
            stopAfterGiveUp(log: "seek \(message)\(issued ? "" : " (never issued)")", report: report)
        }
    }

    /// A native seek ended: one that ended unfinished on its track and was the latest stops
    /// loading (`standardSeekEndStopsLoading`); one a newer seek replaced, or one on an item
    /// AVPlayer cannot seek in (`seekable` false: it completes where the player is), does not.
    func nativeSeekEnded(didFinish: Bool, track: ObjectIdentifier, isLatest: Bool, seekable: Bool, keptPosition: Double) {
        guard !disposed,
              standardSeekEndStopsLoading(didFinish: didFinish, sameTrack: player?.currentLoadItem == track, isLatest: isLatest, seekable: seekable) else { return }
        giveUps.seekGaveUp(
            IOSPlaybackErrorSnapshot(message: "The native seek was interrupted.", code: "standard_seek_cancelled"),
            keptPosition: keptPosition
        ) { report in
            stopAfterGiveUp(log: "seek interrupted", report: report)
        }
    }

    /// Whether the load watch watches the player's loads: not after a give-up, until the next
    /// command (its error stands: the load stopped), nor with no active track (the logical idle:
    /// nothing is reported, not even a load that ends late), nor once disposed.
    var watchesLoads: Bool { return !disposed && giveUps.failure == nil && !(player?.isIdle ?? true) }

    /// A seek, pause or stop that cancelled (`cancelledWait`) a command's wait while its track
    /// loads, or a seek or stop (`actsOnReportedTrack`) while the player is on a track other than
    /// the reported one (owner decision, 2026-11-17), leaves it (`standardCancelledLoad`): back to
    /// the reported track, paused, at `position`
    /// (nil: where the player left that track, read before the move); or, with none reported, the
    /// cancelled load stops and no track is active. Both pause: an ended interruption does not
    /// resume (`requestPlayback(false)`). As Android (KotlinAudioPlaybackBackend.leaveCancelledLoad).
    @discardableResult
    func leaveCancelledLoad(cancelledWait: Bool, position: Double?, actsOnReportedTrack: Bool = false) -> StandardCancelledLoad {
        guard let player = player else { return .stays }
        let left = standardCancelledLoad(cancelledWait: cancelledWait, playerItem: player.currentLoadItem, reported: failedLoads.reported, actsOnReportedTrack: actsOnReportedTrack)
        switch left {
        case .stays:
            break
        case let .returnsTo(target):
            let kept = position ?? player.reportedPosition
            player.requestPlayback(false)
            guard player.jumpPaused(to: target) else { return .stays }
            // A seek issues its own (once the item loaded); SwiftAudioEx defers this one until then.
            if position == nil { player.seekPlayer(to: kept) }
        case .stopsInIdle:
            player.requestPlayback(false)
            player.stopPlayer()
            player.enterIdle()
        }
        return left
    }

    /// A pause (and setPlayWhenReady(false), the same command on Android): the seeks in progress
    /// end; a skip or load still waiting ends cancelled and does not take effect
    /// (`leaveCancelledLoad`); the player pauses, requested paused. A give-up's error stays.
    func pause() {
        guard let player = player else { return }
        playRequestedAtGiveUp = false
        resumesAfterSeek = false
        player.cancelSeeks()
        leaveCancelledLoad(cancelledWait: commandLoads.cancel(), position: nil)
        player.requestPlayback(false)
        player.pausePlayer()
    }

    /// A stop, as Android's: it ends a give-up's error (the app is told the player stopped,
    /// `StandardGiveUps.stopped`), a skip or load still waiting ends cancelled and does not take
    /// effect, after a failed skip the player stops on the active track (owner decision,
    /// 2026-11-17, LOAD-06), the seeks end, and the player stops, requested paused.
    func stop() {
        guard let player = player else { return }
        playRequestedAtGiveUp = false
        resumesAfterSeek = false
        let ended = giveUps.stopped(playerStopped: player.isPlayerStopped)
        _ = failedLoads.command()
        let cancelledWait = commandLoads.cancel()
        player.cancelSeeks()
        leaveCancelledLoad(cancelledWait: cancelledWait, position: nil, actsOnReportedTrack: true)
        player.requestPlayback(false)
        player.stopPlayer()
        if let ended = ended { player.emitGiveUp(ended) }
    }

    /// A seek's start, as a crossfade seek, a newer command: a skip or load still waiting ends
    /// cancelled and does not take effect; the seek acts on the active track, also after a failed
    /// skip and while a natural advance loads (owner decision, 2026-11-17, LOAD-06; none active:
    /// the failed track, retried); the player is no longer in a give-up's error. Returns whether a
    /// track is active to seek in; with none (the logical idle, also after a backend restore with
    /// no active track) the seek resolves at once (`completion`) and nothing loads, as crossfade's
    /// seek with no active track and Android.
    func beginSeek(to position: Double, completion: (Result<Void, Error>) -> Void) -> Bool {
        // After a failed load, the seek goes back to the active track and plays there once done
        // when playback was requested (a failure keeps the request, as crossfade's seek after a
        // failed skip; SwiftAudioEx issues the seek once the item loaded, so not before it).
        var afterFailedLoad = false
        if case .failed = failedLoads.phase { afterFailedLoad = true }
        let playing = giveUps.failure != nil ? playRequestedAtGiveUp : (player?.playbackRequested ?? false)
        let cancelledWait = commandLoads.cancel()
        giveUps.clear()
        _ = failedLoads.command()
        let left = leaveCancelledLoad(cancelledWait: cancelledWait, position: position, actsOnReportedTrack: true)
        if case .returnsTo = left {
            resumesAfterSeek = afterFailedLoad && playing && !cancelledWait
        } else {
            resumesAfterSeek = false
        }
        guard !(player?.isIdle ?? true) else {
            completion(.success(()))
            return false
        }
        return true
    }

    /// The seek `beginSeek` started ended (`succeeded`): it plays when it went back to the active
    /// track after a failed load and playback was requested (`resumesAfterSeek`).
    func seekFinished(succeeded: Bool) {
        guard resumesAfterSeek else { return }
        resumesAfterSeek = false
        if succeeded { player?.resumePlayback() }
    }

    /// A relative seek's target: from the position the app reads (the reported track's, also while
    /// another track loads, where the seek then acts), as crossfade's seekBy and Android.
    func seekTarget(by offset: Double) -> Double {
        return max(0, (player?.reportedPosition ?? 0) + offset)
    }

    /// Ends a load or seek given up (StandardGiveUps decided it, its error is set): the player
    /// stops loading, the app is told (`report`'s events), and the player is in error until the
    /// next command. Its track failed (again, after a seek on a track that failed: the next play
    /// loads the active track; FailedLoadRule.failed changes nothing on the loaded track), as
    /// Android.
    func stopAfterGiveUp(log: String, report: StandardGiveUpReport) {
        guard let player = player else { return }
        playRequestedAtGiveUp = player.playbackRequested
        player.stopLoading(log: log)
        player.emitGiveUp(report)
        failLoadedTrack()
    }

    /// A load failed: the previous track stays active (none when there was none), as the crossfade
    /// path and Android; the lock screen shows it again.
    func failLoadedTrack() {
        guard let player = player else { return }
        player.logFailedLoad(active: failedLoads.active)
        if let change = failedLoads.failed() { player.reportActiveTrack(change) }
        if failedLoads.isPending(player.currentLoadItem) {
            player.showAfterFailedLoad(failedLoads.reported)
        }
        player.followNowPlaying()
    }
}

/// A standard command's result from its wait's outcome (`cancelled`: a newer command replaced it).
func standardCommandLoadResult(_ outcome: StandardCommandLoadOutcome) -> Result<Void, Error> {
    switch outcome {
    case .loaded:
        return .success(())
    case let .failed(code, message):
        return .failure(playbackBackendError(code: code, message: message))
    case .cancelled:
        return .failure(playbackBackendError(code: "cancelled", message: standardCommandLoadCancelledMessage))
    }
}

/// Where SwiftAudioEx's AVPlayer item is: `.unavailable` when the player does not have the
/// expected layout, else its current item (nil: none).
enum StandardPlayerItemLookup {
    case unavailable
    case item(AVPlayerItem?)
}

/// The AVPlayerItem a SwiftAudioEx player plays. SwiftAudioEx 1.1.0 keeps it private
/// (`AudioPlayer.wrapper` → `AVPlayerWrapper.avPlayer`), so it is read by reflection: the exact
/// item from its creation, which AVFoundation fills the access log of before its first
/// `AVPlayerItemNewAccessLogEntry` notification. `.unavailable` with another layout (a SwiftAudioEx
/// update): the load then binds its item from that notification (`StandardLoadBytes.loggedItem`).
/// Reading this private layout is an owner decision (2026-11-17), accepted with the podspec pinned
/// to exactly SwiftAudioEx 1.1.0 (`s.dependency "SwiftAudioEx", "1.1.0"`). Guards:
/// scripts/verify-swiftaudioex-layout.sh runs this function against a real 1.1.0 QueuedAudioPlayer
/// (Mac Catalyst, where the 1.1.0 sources are); testStandardPlayerItemIsReadThroughSwiftAudioExsPrivateWrapper
/// against the layout's fake (CI); verify-ios-crossfade-contracts.js pins the podspec.
func standardPlayerItem(of player: AnyObject) -> StandardPlayerItemLookup {
    var mirror: Mirror? = Mirror(reflecting: player)
    while let current = mirror {
        if let wrapper = current.children.first(where: { $0.label == "wrapper" })?.value {
            guard let avPlayer = Mirror(reflecting: wrapper).children.first(where: { $0.label == "avPlayer" })?.value as? AVPlayer else {
                return .unavailable
            }
            return .item(avPlayer.currentItem)
        }
        mirror = current.superclassMirror
    }
    return .unavailable
}

/// The URL SwiftAudioEx gives a track's asset (its `load(from:type:)`): a file path for a file
/// track, else the URL string.
func standardAssetURL(source: String, isFile: Bool) -> URL? {
    return isFile ? URL(fileURLWithPath: source) : URL(string: source)
}

/// What the standard load watch reads of a load: its progress (`StandardLoadBytes.read`) and its
/// item's buffered time (`StandardLoadBytes.buffered`; the player's buffered position before the
/// load has its item), or nil while SwiftAudioEx's player has no AVPlayerItem (`player`:
/// `standardPlayerItem`): before the asset is playable nothing shows progress, so that stage has
/// only the total limit (`StandardLoadWatch.Watch.playable`), as crossfade's prepare. When the
/// player's item cannot be read (another SwiftAudioEx layout) the readings are kept: the stall
/// rule applies from the load's start, as before (a playlist slower than `stallTimeoutMs` then
/// fails the track).
func standardLoadReadings(_ player: StandardPlayerItemLookup, bytes: Double, buffered: Double) -> [Double]? {
    if case .item(nil) = player { return nil }
    return [bytes, buffered]
}

/// What a standard load reads of its item (an AVPlayerItem, `ItemLoadSnapshot`); nil for another
/// object.
func standardItemLoadSnapshot(_ item: AnyObject) -> ItemLoadSnapshot? {
    return (item as? AVPlayerItem).map(ItemLoadSnapshot.init(of:))
}

/// The standard player's load progress from AVFoundation's access log, the closest to Android's
/// `LoadedBytes` that AVFoundation shows (measured on the iOS 26 simulator with SwiftAudioEx 1.1.0
/// and a local server sending slowly):
/// - Nothing is observable before SwiftAudioEx creates the AVPlayerItem, once the asset's
///   `playable` key loaded (a progressive file's first range requests; an HLS master and media
///   playlist): no item, no access log, no loaded range.
/// - The access log counts media only: an HLS entry appears once the first segment has
///   completely arrived, with that segment's bytes (playlist bytes are not counted), and grows
///   per completed segment; a progressive file's entry exists from the item's creation (with the
///   asset's first requests, `numberOfMediaRequests` > 0 from the start) and grows with every
///   chunk. `AVPlayerItemNewAccessLogEntry` comes only at playback start or a completed
///   segment, and the log grows without it: the load is read at each check.
/// So a load's progress is: one when its item appears (the asset's playable stage done; for HLS,
/// its playlists arrived, the progress Android counts in playlist bytes before the first segment
/// request), then the bytes of its item's access log (media, which Android counts always), read
/// as crossfade's waits read theirs (`ItemLoadProgress`, one per item of the load): after a
/// failed request or a rendition switch (a new error-log entry, or an access-log event that is
/// neither the first one nor that of a seek the backend issued: `noteSeek`), the bytes posted
/// (the left rendition's failed transfers, segments downloaded again) stop counting until new
/// time is buffered. Its buffered reading is the item's time buffered in the load
/// (`buffered`: a buffer that empties and fills again with the same time adds nothing).
///
/// Progress belongs to one load (Android: `startLoad`): its item is the player's own current item
/// (`playerItem`) or, when the player's item cannot be read, the first item of the load's URL that
/// posts an access-log entry after the load started, never one an earlier load had
/// (`loggedItem`), so a previous item's late entries do not count. Main.
final class StandardLoadBytes {
    private final class Earlier {
        weak var item: AnyObject?
        init(_ item: AnyObject) { self.item = item }
    }

    private var url: URL?
    private weak var item: AnyObject?
    /// The load's item's progress (its bytes and buffered time), a new one for each item.
    private var itemProgress = ItemLoadProgress()
    /// The bytes `itemProgress` counted so far.
    private var itemBytes: Double = 0
    private var earlier: [Earlier] = []
    /// The progress of the loads so far: grows with each load's item and bytes.
    private(set) var progress: Double = 0
    /// The time the load's item has buffered in this load (`ItemLoadProgress`'s first reading),
    /// as last read; nil while the load has no item.
    private(set) var buffered: Double?

    /// A new load of the track whose asset is at `url`.
    func startLoad(url: URL?) {
        if let item = item { earlier.append(Earlier(item)) }
        earlier.removeAll { $0.item == nil }
        item = nil
        resetItemProgress()
        self.url = url
    }

    /// The backend is about to issue a seek on the load's item (`snapshot`:
    /// `standardItemLoadSnapshot`): the access-log event a seek past the buffer opens is not a
    /// switch (`ItemLoadProgress.noteSeek(before:)`). Nothing to note while the load has no item
    /// (its first reading is then a baseline that includes the event).
    func noteSeek(_ snapshot: (AnyObject) -> ItemLoadSnapshot?) {
        guard let item = item, let read = snapshot(item) else { return }
        itemProgress.noteSeek(before: read)
    }

    /// The backend's issued seek completed (its native callback, finished or not): what is left
    /// of the seeks' allowance is dropped (`ItemLoadProgress.seekFinished(after:)`), so a seek
    /// inside the buffer, which opens no access-log event, does not leave a later switch counted
    /// as that seek's event. Its bytes are counted at the next `read`.
    func seekFinished(_ snapshot: (AnyObject) -> ItemLoadSnapshot?) {
        guard let item = item, let read = snapshot(item) else { return }
        itemProgress.seekFinished(after: read)
    }

    /// The player's own current item (`standardPlayerItem`): the load's item (a reload within the
    /// load replaces it). SwiftAudioEx's load clears its AVPlayer's item (or makes a new AVPlayer)
    /// before it starts loading, so that item is never an earlier load's; the same item watched
    /// again (a seek owned its loading meanwhile) loads on, as Android's startLoad of that item.
    func playerItem(_ candidate: AnyObject?) {
        guard let candidate = candidate, candidate !== item else { return }
        bind(candidate)
    }

    /// An item posted an access-log entry for `url`: the load's item when the load has none yet,
    /// it is for the load's URL and no earlier load had it. Returns whether it is the load's item.
    @discardableResult
    func loggedItem(_ candidate: AnyObject, url: URL?) -> Bool {
        if candidate === item { return true }
        guard item == nil, let url = url, url == self.url, !hadEarlier(candidate) else { return false }
        bind(candidate)
        return true
    }

    /// Whether an event of `candidate` (an access-log or error entry, a failure) is this load's,
    /// to check the load at once: the player's own item when it can be read, else the load's.
    func isLoadEvent(_ candidate: AnyObject, url: URL?, player: StandardPlayerItemLookup) -> Bool {
        if case let .item(current) = player { return current != nil && current === candidate }
        return loggedItem(candidate, url: url)
    }

    /// The progress after reading the load's item (`snapshot`: `standardItemLoadSnapshot`; nil:
    /// nothing to read).
    func read(_ snapshot: (AnyObject) -> ItemLoadSnapshot?) -> Double {
        guard let item = item, let read = snapshot(item) else { return progress }
        let readings = itemProgress.readings(for: read)
        if readings[1] > itemBytes {
            progress += readings[1] - itemBytes
            itemBytes = readings[1]
        }
        buffered = readings[0]
        return progress
    }

    private func hadEarlier(_ candidate: AnyObject) -> Bool {
        return earlier.contains { $0.item === candidate }
    }

    private func bind(_ candidate: AnyObject) {
        if let item = item { earlier.append(Earlier(item)) }
        item = candidate
        resetItemProgress()
        progress += 1
    }

    private func resetItemProgress() {
        itemProgress = ItemLoadProgress()
        itemBytes = 0
        buffered = nil
    }
}

/// A standard seek's progress once issued, read as crossfade's waits read theirs: the wait's own
/// `ItemLoadProgress` of the player's AVPlayerItem, [seconds of time buffered, counted bytes].
/// The seek is noted with the item just before it is issued (`ItemLoadProgress.noteSeek(before:)`,
/// the wait's baseline), so the access-log event a seek past the buffer opens is not a switch and
/// the media bytes that follow count; after a failed request or a rendition switch the bytes
/// posted are not progress until new time is buffered, and a buffer that empties and fills again
/// with the same time adds nothing. Before, the wait read SwiftAudioEx's buffered position (the end
/// of the last loaded range), which counted such a refill and no media bytes. Another item (the
/// track reloaded) is read from its own start. When SwiftAudioEx's item cannot be read (another
/// layout, no item) the buffered position is read, as before. Main.
final class StandardSeekProgress {
    private let snapshot: (AnyObject) -> ItemLoadSnapshot?
    private weak var item: AnyObject?
    private var progress = ItemLoadProgress()

    /// `snapshot`: `standardItemLoadSnapshot`.
    init(snapshot: @escaping (AnyObject) -> ItemLoadSnapshot?) {
        self.snapshot = snapshot
    }

    /// The backend is about to issue the seek; `player` is SwiftAudioEx's item now
    /// (`standardPlayerItem`).
    func issuing(on player: StandardPlayerItemLookup) {
        guard case let .item(current?) = player, let read = snapshot(current) else { return }
        item = current
        progress = ItemLoadProgress()
        progress.noteSeek(before: read)
    }

    /// The wait's readings: the player's item (`player`) read by this wait's rule, else
    /// SwiftAudioEx's `buffered` position.
    func readings(_ player: StandardPlayerItemLookup, buffered: Double) -> [Double] {
        guard case let .item(current?) = player, let read = snapshot(current) else { return [buffered] }
        if current !== item {
            item = current
            progress = ItemLoadProgress()
        }
        return progress.readings(for: read)
    }
}
