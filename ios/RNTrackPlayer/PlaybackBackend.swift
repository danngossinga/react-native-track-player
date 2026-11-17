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
struct StallWatch {
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

    private func verdict(at now: TimeInterval) -> StallVerdict {
        if capVerdict(at: now) == .capExceeded { return .capExceeded }
        if (now - lastProgressAt) * 1000 >= Double(stallTimeoutMs) { return .stalled }
        return .wait
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
    /// Its progress: the load's bytes (`StandardLoadBytes`) and the buffered position.
    let readings: [Double]
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
    private let stallTimeoutMs: () -> Int
    private let totalTimeoutMs: () -> Int
    private let now: () -> TimeInterval
    private var readyItem: ObjectIdentifier?
    /// The load in progress: its item and when it began (the first time the item was seen
    /// loading, even while a seek owned it). A seek during the load does not end it: once the
    /// seek ends, the load is watched again with its own total limit (a fresh stall clock). As
    /// Android.
    private var loadItem: ObjectIdentifier?
    private var loadStartedAt: TimeInterval = 0
    /// The item whose progress this load started (`startsLoad`), once per load.
    private var progressItem: ObjectIdentifier?
    private var watchedItem: ObjectIdentifier?
    private var watch: StallWatch?
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

    var isWatching: Bool { return watch != nil }

    /// Whether `check` would start a new load's progress with `observed` (its readings aside): an
    /// item loading, not ready since it was loaded and whose load has not started its progress
    /// yet, with no other owner (a load watched again after a seek goes on counting). The caller
    /// starts that load's progress (`StandardLoadBytes.startLoad`) before reading it, as
    /// Android's `onLoadStart`.
    func startsLoad(_ observed: StandardLoadObservation) -> Bool {
        guard let item = observed.item, observed.phase == .loading, !observed.ownedElsewhere else { return false }
        return readyItem != item && !(loadItem == item && progressItem == item)
    }

    /// Takes one observation: the verdict that ends a load the caller must give up, else nil.
    func check(_ observed: StandardLoadObservation) -> StallVerdict? {
        guard let item = observed.item, observed.phase != .failed else {
            readyItem = nil
            endLoad()
            return nil
        }
        if observed.ownedElsewhere {
            disarm()
            // A seek on an item not ready since it was loaded: its load goes on (and its total).
            if observed.phase == .loading, readyItem != item { loadOf(item) }
            return nil
        }
        switch observed.phase {
        case .ready:
            readyItem = item
            endLoad()
            return nil
        case .idle, .failed:
            readyItem = nil
            endLoad()
            return nil
        case .loading:
            break
        }
        if readyItem == item {
            endLoad()
            return nil
        }
        loadOf(item)
        if watch == nil || watchedItem != item {
            var created = StallWatch(stallTimeoutMs: stallTimeoutMs(), totalTimeoutMs: totalTimeoutMs(), startedAt: loadStartedAt)
            created.noteProgress(at: now())
            watch = created
            watchedItem = item
            progressItem = item
            lastStallTimeoutMs = created.stallTimeoutMs
            lastTotalTimeoutMs = created.totalTimeoutMs
        }
        let verdict = watch!.check(at: now(), readings: observed.readings)
        guard verdict != .wait else { return nil }
        endLoad()
        return verdict
    }

    /// `item` is loading: the load in progress, or a new one from now.
    private func loadOf(_ item: ObjectIdentifier) {
        guard loadItem != item else { return }
        loadItem = item
        loadStartedAt = now()
        progressItem = nil
    }

    /// When to check next, in milliseconds, while a load is watched (nil: none): at the moment the
    /// load would give up if nothing progresses, and every `standardLoadSampleIntervalMs` before
    /// it, to read the progress the player does not signal. Same rule as Android.
    func nextCheckInMs() -> Int? {
        guard let watch = watch else { return nil }
        let untilDeadline = max(0, Int(((watch.deadline() - now()) * 1000).rounded(.up)))
        return min(untilDeadline, standardLoadSampleIntervalMs(watch.stallTimeoutMs))
    }

    /// Forgets the load in progress.
    func reset() {
        readyItem = nil
        endLoad()
    }

    private func disarm() {
        watch = nil
        watchedItem = nil
    }

    private func endLoad() {
        disarm()
        loadItem = nil
        progressItem = nil
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
    /// - `failed(item)`: `item`'s load failed (a give-up, a player error); the next play loads the
    ///   active track again, else retries `item`. A move keeps it failed.
    ///
    /// Moves: selecting -moved(x)-> loading(x) (reported at once; x nil: stays); loading/loaded
    /// -moved(x)-> loaded(x) when x is the active track, else loading(x); failed -moved(x)->
    /// failed(x); any -ready-> loaded(item); loading/failed(not active) -failed-> failed(item);
    /// failed -play/command-> loaded/loading (play: the active track, else the failed one); any
    /// -reset-> selecting; -adopted(x)-> loaded(x) (x nil: selecting); published, replaced and
    /// removed keep the kind and follow the item.
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

    /// Another command acts on the player's own track: reported once it loads (no report now).
    func command() -> Report? {
        if case let .failed(failed) = phase { phase = following(failed) }
        return nil
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

    /// The app was told about `item` another way (a logical idle activation).
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
/// unfinished, which is not a failure), as `settleCrossfadeSeek` on the crossfade path. A seek
/// that gives up (`standard_seek_timeout`) stops loading too; a player failure has stopped it.
func standardSeekEndStopsLoading(didFinish: Bool, sameTrack: Bool, isLatest: Bool) -> Bool {
    return !didFinish && sameTrack && isLatest
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

    /// A newer command that loads, seeks or stops: the wait in progress ends cancelled.
    func cancel() {
        guard let current = wait else { return }
        wait = nil
        current.settle(.cancelled)
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
struct StandardGiveUpReport {
    let failure: IOSPlaybackErrorSnapshot
    let reportsPlaybackError: Bool

    /// The events in order, by name (`EventType`'s raw value) with their body.
    var events: [(name: String, body: [String: Any])] {
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

/// The bytes each access-log entry of `item` (an AVPlayerItem) reports transferred.
func standardAccessLogBytes(_ item: AnyObject) -> [Int64] {
    return (item as? AVPlayerItem)?.accessLog()?.events.map { $0.numberOfBytesTransferred } ?? []
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
/// request), then every byte of its item's access log (media, which Android counts always).
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
    private var itemBytes: Int64 = 0
    private var earlier: [Earlier] = []
    /// The progress of the loads so far: grows with each load's item and bytes.
    private(set) var progress: Double = 0

    /// A new load of the track whose asset is at `url`.
    func startLoad(url: URL?) {
        if let item = item { earlier.append(Earlier(item)) }
        earlier.removeAll { $0.item == nil }
        item = nil
        itemBytes = 0
        self.url = url
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

    /// The progress after reading the load's item's access log (`entries`: bytes per entry,
    /// negative when unknown).
    func read(_ entries: (AnyObject) -> [Int64]) -> Double {
        guard let item = item else { return progress }
        let total = entries(item).reduce(Int64(0)) { $0 + max(0, $1) }
        if total > itemBytes {
            progress += Double(total - itemBytes)
            itemBytes = total
        }
        return progress
    }

    private func hadEarlier(_ candidate: AnyObject) -> Bool {
        return earlier.contains { $0.item === candidate }
    }

    private func bind(_ candidate: AnyObject) {
        if let item = item { earlier.append(Earlier(item)) }
        item = candidate
        itemBytes = 0
        progress += 1
    }
}
