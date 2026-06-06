package com.doublesymmetry.trackplayer.service

import com.doublesymmetry.trackplayer.model.TrackAudioItem

internal class AndroidTrackQueue {
    private val items = mutableListOf<TrackAudioItem>()

    fun snapshot(): List<TrackAudioItem> = items.toList()

    fun isEmpty(): Boolean = items.isEmpty()

    fun getOrNull(index: Int): TrackAudioItem? = items.getOrNull(index)

    fun indexOfQueueId(queueId: Long): Int {
        return items.indexOfFirst { it.track.queueId == queueId }
    }

    fun replaceWith(nextItems: List<TrackAudioItem>) {
        items.clear()
        items.addAll(nextItems)
    }

    fun add(nextItems: List<TrackAudioItem>) {
        items.addAll(nextItems)
    }

    fun add(nextItems: List<TrackAudioItem>, atIndex: Int) {
        items.addAll(atIndex.coerceIn(0, items.size), nextItems)
    }

    fun move(fromIndex: Int, toIndex: Int) {
        if (fromIndex !in items.indices) return
        val item = items.removeAt(fromIndex)
        items.add(toIndex.coerceIn(0, items.size), item)
    }

    fun remove(indexes: List<Int>) {
        indexes
            .distinct()
            .filter { it in items.indices }
            .sortedDescending()
            .forEach { items.removeAt(it) }
    }

    fun removeUpcoming(currentIndex: Int) {
        if (currentIndex < 0) return
        remove((currentIndex + 1 until items.size).toList())
    }

    fun removePrevious(currentIndex: Int) {
        if (currentIndex <= 0) return
        remove((0 until currentIndex.coerceAtMost(items.size)).toList())
    }

    fun replace(index: Int, item: TrackAudioItem) {
        if (index in items.indices) {
            items[index] = item
        }
    }

    fun clear() {
        items.clear()
    }
}
