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
    /// Its progress: the buffered position (the only one SwiftAudioEx exposes).
    let readings: [Double]
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

    /// Takes one observation: the verdict that ends a load the caller must give up, else nil.
    func check(_ observed: StandardLoadObservation) -> StallVerdict? {
        guard let item = observed.item, observed.phase != .failed else {
            readyItem = nil
            disarm()
            return nil
        }
        switch observed.phase {
        case .ready:
            readyItem = item
            disarm()
            return nil
        case .idle, .failed:
            readyItem = nil
            disarm()
            return nil
        case .loading:
            break
        }
        if readyItem == item {
            disarm()
            return nil
        }
        if watch == nil || watchedItem != item {
            let created = StallWatch(stallTimeoutMs: stallTimeoutMs(), totalTimeoutMs: totalTimeoutMs(), startedAt: now())
            watch = created
            watchedItem = item
            lastStallTimeoutMs = created.stallTimeoutMs
            lastTotalTimeoutMs = created.totalTimeoutMs
        }
        let verdict = watch!.check(at: now(), readings: observed.readings)
        guard verdict != .wait else { return nil }
        disarm()
        return verdict
    }

    /// Forgets the load in progress.
    func reset() {
        readyItem = nil
        disarm()
    }

    private func disarm() {
        watch = nil
        watchedItem = nil
    }
}

/// The message of a load that gave up (Android: `standardLoadGiveUpMessage`, same text).
func standardLoadGiveUpMessage(_ verdict: StallVerdict, stallTimeoutMs: Int, totalTimeoutMs: Int) -> String {
    return "The track did not become ready (" +
        (verdict == .stalled ? "no progress for \(stallTimeoutMs)ms" : "over the \(totalTimeoutMs)ms limit") +
        ")."
}

/// Which track is active around a load, as the crossfade loadIndex decides it (chosen alignment
/// for both backends and both platforms; Android: `FailedLoadRule`, same rules): a track becomes
/// the active one once it loaded (ready); when its load fails (a give-up, a player error) the
/// previous track stays active (none when there was none), and the next play loads that previous
/// track. Items are compared by identity. Shared scenarios:
/// scripts/fixtures/failed-load-scenarios.json.
///
/// A standard player moves to an item before it loads and reports it then (`moved`); the rule
/// also keeps what the app was last told, so each correction is reported once: back to the
/// previous track when a load fails (`failed`), to the player's own track when a command acts
/// after that (`command`) or when a track never reported becomes ready (`ready`), and not again
/// when a play reloads the previous track (`play`, then `moved`).
final class FailedLoadRule {
    /// A change of the active track to report: `to` (nil: none).
    struct Revert: Equatable {
        let to: ObjectIdentifier?
    }
    typealias Report = Revert

    private var current: ObjectIdentifier?
    private var reported: ObjectIdentifier?
    private(set) var active: ObjectIdentifier?
    /// A failed load was reverted and no command has acted since: `active` is what to report.
    private(set) var isReverted = false

    /// The player is on `item` (polled).
    func loaded(_ item: ObjectIdentifier?) {
        current = item
    }

    /// The player moved to `item` and would report it: whether to (false: the app has it).
    func moved(_ item: ObjectIdentifier?) -> Bool {
        current = item
        guard item != reported else { return false }
        reported = item
        return true
    }

    /// The current item is ready: it is the active track; a report when the app was not told.
    func ready() -> Report? {
        active = current
        isReverted = false
        guard current != reported else { return nil }
        reported = current
        return Report(to: current)
    }

    /// The current item's load failed: the revert to report, or nil when it was the active one.
    func failed() -> Report? {
        guard current != active else { return nil }
        isReverted = true
        reported = active
        return Report(to: active)
    }

    /// A play: the item to load first (the active one after a revert), or nil to play the current.
    func play() -> ObjectIdentifier? {
        guard isReverted else { return nil }
        isReverted = false
        guard let target = active else { return nil }
        current = target
        return target
    }

    /// Another command acts on the player's own track: a report when the app was told another.
    func command() -> Report? {
        guard isReverted else { return nil }
        isReverted = false
        guard current != reported else { return nil }
        reported = current
        return Report(to: current)
    }
}
