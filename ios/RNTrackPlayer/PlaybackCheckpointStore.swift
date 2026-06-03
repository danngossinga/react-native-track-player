//
//  PlaybackCheckpointStore.swift
//  RNTrackPlayer
//

import Foundation

struct PlaybackCheckpoint: Codable {
    let version: Int
    let updatedAt: TimeInterval
    let queueHash: String
    let currentIndex: Int
    let position: Double
    let duration: Double
    let playWhenReady: Bool
    let state: String
}

final class PlaybackCheckpointStore {
    private let fileManager: FileManager
    private let fileURL: URL
    private var memoryCheckpoint: PlaybackCheckpoint?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = appSupport.appendingPathComponent("RNTrackPlayer", isDirectory: true)
        self.fileURL = directory.appendingPathComponent("playback-checkpoint.json")
        createStorageDirectory(directory)
        self.memoryCheckpoint = readFromDisk()
    }

    func save(_ checkpoint: PlaybackCheckpoint) {
        memoryCheckpoint = checkpoint
        do {
            let data = try JSONEncoder().encode(checkpoint)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            IOSPlaybackLog.log("checkpoint persist failed error=\(error.localizedDescription)")
        }
    }

    func load(queueHash: String, currentIndex: Int) -> PlaybackCheckpoint? {
        if let checkpoint = memoryCheckpoint,
           checkpoint.queueHash == queueHash,
           checkpoint.currentIndex == currentIndex {
            return checkpoint
        }
        guard let checkpoint = readFromDisk(),
              checkpoint.queueHash == queueHash,
              checkpoint.currentIndex == currentIndex else {
            return nil
        }
        memoryCheckpoint = checkpoint
        return checkpoint
    }

    func clear() {
        memoryCheckpoint = nil
        try? fileManager.removeItem(at: fileURL)
    }

    private func createStorageDirectory(_ directory: URL) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var excludedURL = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excludedURL.setResourceValues(values)
        } catch {
            IOSPlaybackLog.log("checkpoint directory failed error=\(error.localizedDescription)")
        }
    }

    private func readFromDisk() -> PlaybackCheckpoint? {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(PlaybackCheckpoint.self, from: data)
        } catch {
            return nil
        }
    }
}
