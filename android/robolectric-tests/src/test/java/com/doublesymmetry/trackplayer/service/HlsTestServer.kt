package com.doublesymmetry.trackplayer.service

import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

/**
 * A local HLS server for tests that run a real ExoPlayer. It serves a master playlist with audio
 * renditions (in the order given), a VOD media playlist per rendition of [segmentCount] segments
 * of [SEGMENT_SECONDS] s, and the segments: synthetic AAC (ADTS) audio for those before
 * [stalledFrom], and for the others nothing at all: the request is accepted and never answered,
 * like a stalled CDN, until the client closes it; or, with [failingStatus], an HTTP error after
 * [failingAfterMs] (a CDN that fails, which makes the player fall back to another rendition).
 * It records every request and every stalled request the client closed, in order.
 */
internal class HlsTestServer(
    /** The renditions, in master playlist order: (name, BANDWIDTH in bits per second). */
    private val renditions: List<Pair<String, Int>>,
    private val segmentCount: Int = 2,
    /** The first segment that never arrives (0: none does). */
    private val stalledFrom: Int = 0,
    /** When set, the segments from [stalledFrom] on answer this HTTP status instead of stalling. */
    private val failingStatus: Int? = null,
    private val failingAfterMs: Long = 0L,
    /** When set, the master playlist's body instead of the renditions (a broken playlist). */
    private val masterBody: String? = null,
    /** How long the master and each media playlist take to answer (a busy proxy or origin). */
    private val playlistDelayMs: Long = 0L
) : AutoCloseable {
    private val released = CountDownLatch(1)
    private val socket = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
    private val pool = Executors.newCachedThreadPool()
    private val openConnections: MutableList<Socket> = Collections.synchronizedList(mutableListOf())

    /** Request paths, in arrival order. */
    val requests: MutableList<String> = Collections.synchronizedList(mutableListOf())

    /** Arrival time (monotonic, ms) of each stalled segment request, in order. */
    val stalledRequestTimesMs: MutableList<Long> = Collections.synchronizedList(mutableListOf())

    /** Time (monotonic, ms) at which the client closed each stalled request, in order. */
    val stalledRequestClosedTimesMs: MutableList<Long> = Collections.synchronizedList(mutableListOf())

    val masterUrl: String
        get() = "http://127.0.0.1:${socket.localPort}/master.m3u8"

    init {
        pool.execute {
            while (!socket.isClosed) {
                val connection = runCatching { socket.accept() }.getOrNull() ?: break
                openConnections += connection
                pool.execute { serve(connection) }
            }
        }
    }

    private fun serve(connection: Socket) {
        runCatching {
            val reader = BufferedReader(InputStreamReader(connection.getInputStream()))
            while (!connection.isClosed) {
                val requestLine = reader.readLine() ?: break
                // Skip the headers (the requests have no body).
                while (true) {
                    val header = reader.readLine() ?: return
                    if (header.isEmpty()) break
                }
                val path = requestLine.split(' ').getOrNull(1)?.substringBefore('?') ?: break
                requests += path
                val segment = SEGMENT_NAME.matchEntire(path.substringAfterLast('/'))?.groupValues?.get(1)?.toInt()
                when {
                    path == "/master.m3u8" -> {
                        Thread.sleep(playlistDelayMs)
                        respond(connection, (masterBody ?: masterPlaylist()).toByteArray(), PLAYLIST_TYPE)
                    }
                    path.endsWith("/index.m3u8") -> {
                        Thread.sleep(playlistDelayMs)
                        respond(connection, mediaPlaylist().toByteArray(), PLAYLIST_TYPE)
                    }
                    segment != null && segment >= stalledFrom && failingStatus != null -> {
                        stalledRequestTimesMs += monotonicNowMs()
                        Thread.sleep(failingAfterMs)
                        respond(connection, ByteArray(0), "audio/aac", status = "$failingStatus Failing")
                    }
                    segment != null && segment >= stalledFrom -> {
                        stallUntilClosed(connection)
                        return
                    }
                    segment != null -> respond(connection, adtsSegment(segment), "audio/aac")
                    else -> respond(connection, ByteArray(0), PLAYLIST_TYPE, status = "404 Not Found")
                }
            }
        }
        runCatching { connection.close() }
    }

    /** Sends nothing; notes when the client gives up on the request and closes it. */
    private fun stallUntilClosed(connection: Socket) {
        stalledRequestTimesMs += monotonicNowMs()
        connection.soTimeout = 20
        val input = connection.getInputStream()
        while (released.count > 0) {
            val closed = try {
                input.read() == -1
            } catch (_: SocketTimeoutException) {
                false
            } catch (_: Exception) {
                true
            }
            if (closed) {
                stalledRequestClosedTimesMs += monotonicNowMs()
                break
            }
        }
        runCatching { connection.close() }
    }

    private fun respond(connection: Socket, bytes: ByteArray, type: String, status: String = "200 OK") {
        val head = "HTTP/1.1 $status\r\nContent-Type: $type\r\nContent-Length: ${bytes.size}\r\n\r\n"
        connection.getOutputStream().apply {
            write(head.toByteArray())
            write(bytes)
            flush()
        }
    }

    private fun masterPlaylist(): String = buildString {
        append("#EXTM3U\n#EXT-X-VERSION:3\n")
        for ((name, bandwidth) in renditions) {
            append("#EXT-X-STREAM-INF:BANDWIDTH=$bandwidth,AVERAGE-BANDWIDTH=$bandwidth,CODECS=\"mp4a.40.2\"\n")
            append("$name/index.m3u8\n")
        }
    }

    private fun mediaPlaylist(): String = buildString {
        append("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:$SEGMENT_SECONDS\n")
        append("#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n")
        for (index in 0 until segmentCount) {
            append("#EXTINF:$SEGMENT_SECONDS.0,\n").append(segmentName(index)).append('\n')
        }
        append("#EXT-X-ENDLIST\n")
    }

    /** The renditions whose segments the player asked for, in order. */
    fun segmentRenditions(): List<String> =
        synchronized(requests) { requests.filter { SEGMENT_NAME.matches(it.substringAfterLast('/')) } }
            .map { it.removePrefix("/").substringBefore('/') }

    override fun close() {
        released.countDown()
        runCatching { socket.close() }
        synchronized(openConnections) { openConnections.forEach { runCatching { it.close() } } }
        pool.shutdownNow()
    }

    internal companion object {
        const val SEGMENT_SECONDS = 4
        private const val PLAYLIST_TYPE = "application/vnd.apple.mpegurl"
        private val SEGMENT_NAME = Regex("segment-(\\d+)\\.aac")
        private const val SAMPLE_RATE = 44_100
        private const val SAMPLES_PER_FRAME = 1_024
        private const val FRAME_PAYLOAD_BYTES = 32

        fun segmentName(index: Int) = "segment-%03d.aac".format(index)

        /**
         * One packed-audio HLS segment: the ID3 timestamp HLS requires, then AAC LC frames
         * (44.1 kHz, stereo) with filler payloads (the tests' decoder copies bytes; nothing is
         * decoded).
         */
        fun adtsSegment(index: Int): ByteArray {
            val out = ByteArrayOutputStream()
            out.write(id3Timestamp(index.toLong() * SEGMENT_SECONDS * 90_000L))
            val frames = (SEGMENT_SECONDS * SAMPLE_RATE + SAMPLES_PER_FRAME - 1) / SAMPLES_PER_FRAME
            val frameLength = 7 + FRAME_PAYLOAD_BYTES
            repeat(frames) {
                out.write(
                    byteArrayOf(
                        0xFF.toByte(),
                        0xF1.toByte(), // MPEG-4, no CRC
                        ((1 shl 6) or (4 shl 2)).toByte(), // AAC LC, 44.1 kHz
                        ((2 shl 6) or (frameLength shr 11)).toByte(), // 2 channels
                        ((frameLength shr 3) and 0xFF).toByte(),
                        (((frameLength and 7) shl 5) or 0x1F).toByte(),
                        0xFC.toByte()
                    )
                )
                out.write(ByteArray(FRAME_PAYLOAD_BYTES))
            }
            return out.toByteArray()
        }

        /** An ID3v2.4 tag with the PRIV frame HLS packed audio starts with (a 90 kHz timestamp). */
        private fun id3Timestamp(timestamp90k: Long): ByteArray {
            val owner = "com.apple.streaming.transportStreamTimestamp".toByteArray() + 0
            val stamp = ByteArray(8) { i -> ((timestamp90k ushr (8 * (7 - i))) and 0xFF).toByte() }
            val frameBody = owner + stamp
            val frame = "PRIV".toByteArray() + syncSafe(frameBody.size) + byteArrayOf(0, 0) + frameBody
            return "ID3".toByteArray() + byteArrayOf(4, 0, 0) + syncSafe(frame.size) + frame
        }

        private fun syncSafe(value: Int): ByteArray = byteArrayOf(
            ((value shr 21) and 0x7F).toByte(),
            ((value shr 14) and 0x7F).toByte(),
            ((value shr 7) and 0x7F).toByte(),
            (value and 0x7F).toByte()
        )
    }
}
