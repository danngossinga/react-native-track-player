//
//  Metadata.swift
//  RNTrackPlayer
//
//  Created by David Chavez on 23.06.19.
//  Copyright © 2019 David Chavez. All rights reserved.
//

import Foundation
import MediaPlayer
import SwiftAudioEx

struct Metadata {
    private static var currentImageTask: URLSessionDataTask?

    /// `controller`: where to write (default: the player's own; the standard player's `direct`
    /// writes while its own updates are held, StandardNowPlayingInfoController).
    static func update(for player: AudioPlayer, with metadata: [String: Any], through controller: NowPlayingInfoControllerProtocol? = nil) {
        currentImageTask?.cancel()
        let target = controller ?? player.nowPlayingInfoController
        var ret: [NowPlayingInfoKeyValue] = []
        
        if let title = metadata["title"] as? String {
            ret.append(MediaItemProperty.title(title))
        }
        
        if let artist = metadata["artist"] as? String {
            ret.append(MediaItemProperty.artist(artist))
        }
        
        if let album = metadata["album"] as? String {
            ret.append(MediaItemProperty.albumTitle(album))
        }
        
        if let duration = metadata["duration"] as? Double {
            ret.append(MediaItemProperty.duration(duration))
        }
        
        if let elapsedTime = metadata["elapsedTime"] as? Double {
            ret.append(NowPlayingInfoProperty.elapsedPlaybackTime(elapsedTime))
        }

        if let isLiveStream = metadata["isLiveStream"] as? Bool {
            ret.append(NowPlayingInfoProperty.isLiveStream(isLiveStream))
        }
        
        target.set(keyValues: ret)
        
        if let artworkURL = MediaURL(object: metadata["artwork"]) {
            currentImageTask = URLSession.shared.dataTask(with: artworkURL.value, completionHandler: { (data, _, error) in
                if let data = data, let image = UIImage(data: data), error == nil {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size, requestHandler: { (size) -> UIImage in
                        return image
                    })
                    target.set(keyValue: MediaItemProperty.artwork(artwork))
                }
            })
            
            currentImageTask?.resume()
        } else {
            target.set(keyValue: MediaItemProperty.artwork(nil))
        }
    }
}
