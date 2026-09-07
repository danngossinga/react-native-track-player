import Foundation

class EventEmitter {

    public static var shared = EventEmitter()

    private var eventEmitter: RNTrackPlayer!
    var onEmit: ((EventType, Any?) -> Void)?

    func register(eventEmitter: RNTrackPlayer) {
        self.eventEmitter = eventEmitter
    }

    func emit(event: EventType, body: Any?) {
        onEmit?(event, body)
        self.eventEmitter.sendEvent(withName: event.rawValue, body: body)
    }
}
