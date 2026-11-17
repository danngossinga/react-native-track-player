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
 * It records every request and every stalled request the client closed, in order. It also serves
 * [streamUrl]: a raw ADTS stream (as an internet radio's), not HLS.
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
    private val playlistDelayMs: Long = 0L,
    /**
     * When set, the segments are AES-128 encrypted (EXT-X-KEY) and the key takes this long to
     * answer; null: clear segments.
     */
    private val keyDelayMs: Long? = null,
    /** How long a served segment takes before its first byte. */
    private val segmentDelayMs: Long = 0L,
    /**
     * Segments from this one on come slowly but steadily: the ID3 header, a pause of
     * [trickleGapMs], a few bytes (less than an audio frame), another pause, then the rest.
     * -1: none.
     */
    private val trickleFrom: Int = -1,
    private val trickleGapMs: Long = 0L
) : AutoCloseable {
    private val released = CountDownLatch(1)
    private val socket = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
    private val pool = Executors.newCachedThreadPool()
    private val openConnections: MutableList<Socket> = Collections.synchronizedList(mutableListOf())

    /** Request paths, in arrival order. */
    val requests: MutableList<String> = Collections.synchronizedList(mutableListOf())

    /** Arrival time (monotonic, ms) of each request in [requests]. */
    private val requestTimesMs: MutableList<Long> = Collections.synchronizedList(mutableListOf())

    /** When the first request whose path matches arrived (monotonic, ms), or null. */
    fun firstRequestAtMs(matches: (String) -> Boolean): Long? = synchronized(requests) {
        requests.indexOfFirst(matches).takeIf { it >= 0 }?.let { requestTimesMs[it] }
    }

    /** Arrival time (monotonic, ms) of each stalled segment request, in order. */
    val stalledRequestTimesMs: MutableList<Long> = Collections.synchronizedList(mutableListOf())

    /** Time (monotonic, ms) at which the client closed each stalled request, in order. */
    val stalledRequestClosedTimesMs: MutableList<Long> = Collections.synchronizedList(mutableListOf())

    val masterUrl: String
        get() = "http://127.0.0.1:${socket.localPort}/master.m3u8"

    val port: Int
        get() = socket.localPort

    /**
     * A raw ADTS stream of one segment's audio ([SEGMENT_SECONDS] s), sent with no Content-Length
     * and ended by closing the connection: ExoPlayer cannot seek in it (no length, so no
     * constant-bitrate seeking; its window is not seekable).
     */
    val streamUrl: String
        get() = "http://127.0.0.1:${socket.localPort}$STREAM_PATH"

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
                synchronized(requests) {
                    requests += path
                    requestTimesMs += monotonicNowMs()
                }
                val segment = SEGMENT_NAME.matchEntire(path.substringAfterLast('/'))?.groupValues?.get(1)?.toInt()
                when {
                    path == STREAM_PATH -> {
                        val head = "HTTP/1.1 200 OK\r\nContent-Type: audio/aac\r\nConnection: close\r\n\r\n"
                        connection.getOutputStream().apply {
                            write(head.toByteArray())
                            write(adtsSegment(0))
                            flush()
                        }
                        runCatching { connection.close() }
                        return
                    }
                    path == "/master.m3u8" -> {
                        Thread.sleep(playlistDelayMs)
                        respond(connection, (masterBody ?: masterPlaylist()).toByteArray(), PLAYLIST_TYPE)
                    }
                    path.endsWith("/index.m3u8") -> {
                        Thread.sleep(playlistDelayMs)
                        respond(connection, mediaPlaylist().toByteArray(), PLAYLIST_TYPE)
                    }
                    path.endsWith("/$KEY_FILE") && keyDelayMs != null -> {
                        Thread.sleep(keyDelayMs)
                        respond(connection, KEY, "application/octet-stream")
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
                    segment != null && trickleFrom in 0..segment ->
                        respondInSteps(connection, adtsSegment(segment), "audio/aac")
                    segment != null -> {
                        Thread.sleep(segmentDelayMs)
                        val clear = adtsSegment(segment)
                        respond(connection, if (keyDelayMs != null) encrypt(clear) else clear, "audio/aac")
                    }
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

    /** Headers and the ID3 tag, a pause, a few bytes, a pause, the rest (see [trickleFrom]). */
    private fun respondInSteps(connection: Socket, bytes: ByteArray, type: String) {
        val head = "HTTP/1.1 200 OK\r\nContent-Type: $type\r\nContent-Length: ${bytes.size}\r\n\r\n"
        val id3 = ID3_TAG_BYTES
        val few = TRICKLE_STEP_BYTES
        connection.getOutputStream().apply {
            write(head.toByteArray())
            write(bytes, 0, id3)
            flush()
            Thread.sleep(trickleGapMs)
            write(bytes, id3, few)
            flush()
            Thread.sleep(trickleGapMs)
            write(bytes, id3 + few, bytes.size - id3 - few)
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
        if (keyDelayMs != null) append("#EXT-X-KEY:METHOD=AES-128,URI=\"$KEY_FILE\",IV=0x$IV_HEX\n")
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
        private const val STREAM_PATH = "/stream.aac"
        private const val SAMPLE_RATE = 44_100
        private const val SAMPLES_PER_FRAME = 1_024
        private const val FRAME_PAYLOAD_BYTES = 32
        /** The ID3 tag at the start of each segment (header and timestamp frame). */
        private val ID3_TAG_BYTES = id3Timestamp(0L).size
        /** Fewer bytes than one audio frame: they arrive, but no media can be read from them. */
        private const val TRICKLE_STEP_BYTES = 7 + FRAME_PAYLOAD_BYTES - 1

        fun segmentName(index: Int) = "segment-%03d.aac".format(index)

        private const val KEY_FILE = "key.bin"
        private val KEY = "0123456789abcdef".toByteArray()
        private const val IV_HEX = "ed2425f2779b684e97fc315b2b1cb450"

        /** AES-128-CBC with PKCS#7 padding, as HLS (javax.crypto, offline). */
        private fun encrypt(clear: ByteArray): ByteArray {
            val iv = IV_HEX.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
            val cipher = javax.crypto.Cipher.getInstance("AES/CBC/PKCS5Padding")
            cipher.init(
                javax.crypto.Cipher.ENCRYPT_MODE,
                javax.crypto.spec.SecretKeySpec(KEY, "AES"),
                javax.crypto.spec.IvParameterSpec(iv)
            )
            return cipher.doFinal(clear)
        }

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
