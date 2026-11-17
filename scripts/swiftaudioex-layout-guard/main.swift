// The guard of verify-swiftaudioex-layout.sh: standardPlayerItem (ios/RNTrackPlayer/PlaybackBackend.swift,
// compiled with this file as is) against a real SwiftAudioEx 1.1.0 QueuedAudioPlayer. The standard
// load's byte progress reads the player's AVPlayerItem through SwiftAudioEx's private layout
// (AudioPlayer.wrapper -> AVPlayerWrapper.avPlayer) by reflection, an owner decision
// (2026-11-17) that holds only with SwiftAudioEx pinned to exactly 1.1.0: this fails when that
// layout is not what the function reads.
import AVFoundation
import Foundation
import SwiftAudioEx

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

let player = QueuedAudioPlayer()
guard case .item(nil) = standardPlayerItem(of: player) else {
    fail("before a load, standardPlayerItem must read the AVPlayer's empty item (got another result: the layout changed)")
}

// A short silent file: SwiftAudioEx loads its asset, then gives the AVPlayer an item for it.
let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("swiftaudioex-layout-guard-\(getpid()).caf")
do {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
    buffer.frameLength = 44_100
    try file.write(from: buffer)
} catch {
    fail("could not write the test file: \(error)")
}
defer { try? FileManager.default.removeItem(at: url) }

player.load(item: DefaultAudioItem(audioUrl: url.path, sourceType: .file), playWhenReady: false)
let deadline = Date().addingTimeInterval(10)
while Date() < deadline {
    switch standardPlayerItem(of: player) {
    case .unavailable:
        fail("standardPlayerItem found no AudioPlayer.wrapper -> AVPlayerWrapper.avPlayer: SwiftAudioEx's layout changed")
    case let .item(item?):
        guard let asset = item.asset as? AVURLAsset, asset.url.standardizedFileURL == url.standardizedFileURL else {
            fail("the item read is not the one SwiftAudioEx loaded: \(item.asset)")
        }
        print("OK: standardPlayerItem reads SwiftAudioEx 1.1.0's AVPlayer item (\(url.lastPathComponent))")
        exit(0)
    case .item(nil):
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}
fail("SwiftAudioEx gave its AVPlayer no item within 10 s")
