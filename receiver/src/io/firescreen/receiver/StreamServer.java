package io.firescreen.receiver;

import android.media.MediaCodec;
import android.media.MediaFormat;
import android.util.Log;
import android.view.Surface;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.EOFException;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;

/**
 * Accepts one sender at a time and decodes its H.264 stream onto the surface.
 *
 * Wire protocol v1, every packet: [type u8][length u32 big-endian][payload].
 *   1 CONFIG  ascii "width,height,fps[,playoutDelayMs[,avc|hevc]]"; (re)creates the decoder
 *   2 FRAME   one H.264 access unit, Annex B
 *   3 CODEC   SPS + PPS, Annex B, queued as codec config
 *   4 TIMED   [capture time us, i64 big-endian][access unit]; presented at the sender's cadence
 *   5 AUDIO   [capture time us of first sample, i64 big-endian][s16le interleaved PCM]
 *   6 AUDIOCFG ascii "sampleRate,channels"; (re)creates the audio player
 *   7 AVOFFSET ascii "offsetMs,persist"; positive plays audio later; persist=1 stores it for this TV
 *
 * Receiver to sender, once on connect:
 *   1 HELLO   ascii "protocolVersion|avOffsetMs|deviceName"
 */
final class StreamServer extends Thread {

    /** This TV's audio/video offset, kept on the device so any Mac gets it. */
    interface Settings {
        long avOffsetMs();

        void saveAvOffsetMs(long ms);

        String deviceName();
    }

    interface Listener {
        void onStreaming(String description);

        void onIdle(String reason);
    }

    private static final String TAG = "FireScreen";
    private static final int TYPE_CONFIG = 1;
    private static final int TYPE_FRAME = 2;
    private static final int TYPE_CODEC = 3;
    private static final int TYPE_TIMED = 4;
    private static final int TYPE_AUDIO = 5;
    private static final int TYPE_AUDIO_CONFIG = 6;
    private static final int TYPE_AV_OFFSET = 7;
    private static final int TYPE_HELLO = 1;
    static final int PROTOCOL_VERSION = 1;
    private static final int MAX_PACKET = 8 * 1024 * 1024;
    static final Stats STATS = new Stats();
    /** Per-frame in/out log for latency debugging: adb shell setprop log.tag.FireScreenTrace VERBOSE */
    static final boolean TRACE = Log.isLoggable("FireScreenTrace", Log.VERBOSE);

    private final int port;
    private final Surface surface;
    private final Listener listener;
    private final Settings settings;
    private volatile boolean running = true;
    private ServerSocket serverSocket;
    private Socket client;

    StreamServer(int port, Surface surface, Listener listener, Settings settings) {
        super("firescreen-server");
        this.port = port;
        this.surface = surface;
        this.listener = listener;
        this.settings = settings;
    }

    void shutdown() {
        running = false;
        closeQuietly(client);
        try {
            if (serverSocket != null) serverSocket.close();
        } catch (IOException ignored) {
        }
    }

    @Override
    public void run() {
        try {
            serverSocket = new ServerSocket();
            serverSocket.setReuseAddress(true);
            serverSocket.bind(new InetSocketAddress(port));
        } catch (IOException e) {
            listener.onIdle("Port " + port + " unavailable: " + e.getMessage());
            return;
        }
        while (running) {
            try {
                client = serverSocket.accept();
                client.setTcpNoDelay(true);
                client.setReceiveBufferSize(1024 * 1024);
                Log.i(TAG, "sender connected: " + client.getRemoteSocketAddress());
                serve(client);
                listener.onIdle("Mac disconnected");
            } catch (IOException e) {
                if (running) listener.onIdle("Error: " + e.getMessage());
            } finally {
                closeQuietly(client);
            }
        }
    }

    private void serve(Socket socket) throws IOException {
        DataInputStream in = new DataInputStream(new BufferedInputStream(socket.getInputStream(), 256 * 1024));
        PlayoutClock clock = new PlayoutClock();
        clock.setAvOffsetNs(settings.avOffsetMs() * 1_000_000L);
        sendHello(socket);
        Decoder decoder = null;
        AudioPlayer audio = null;
        byte[] buf = new byte[512 * 1024];
        try {
            while (running) {
                int type;
                try {
                    type = in.readUnsignedByte();
                } catch (EOFException eof) {
                    return;
                }
                int length = in.readInt();
                if (length < 0 || length > MAX_PACKET) throw new IOException("bad packet length " + length);
                if (length > buf.length) buf = new byte[length];
                in.readFully(buf, 0, length);

                switch (type) {
                    case TYPE_CONFIG: {
                        String[] parts = new String(buf, 0, length, StandardCharsets.US_ASCII).split(",");
                        int width = Integer.parseInt(parts[0].trim());
                        int height = Integer.parseInt(parts[1].trim());
                        int fps = Integer.parseInt(parts[2].trim());
                        long delayMs = parts.length > 3 ? Long.parseLong(parts[3].trim()) : 50;
                        String mime = parts.length > 4 && parts[4].trim().equals("hevc")
                                ? MediaFormat.MIMETYPE_VIDEO_HEVC : MediaFormat.MIMETYPE_VIDEO_AVC;
                        if (decoder != null) decoder.release();
                        clock.setPlayoutDelayNs(delayMs * 1_000_000L);
                        decoder = new Decoder(surface, mime, width, height, fps, clock);
                        listener.onStreaming(width + "x" + height + "@" + fps);
                        break;
                    }
                    case TYPE_CODEC:
                        if (decoder != null) decoder.queue(buf, 0, length, MediaCodec.BUFFER_FLAG_CODEC_CONFIG, 0);
                        break;
                    case TYPE_FRAME:
                        STATS.received(length);
                        long nowUs = System.nanoTime() / 1000;
                        STATS.arrivalJitter(clock.arrived(nowUs));
                        if (decoder != null) decoder.queue(buf, 0, length, 0, nowUs);
                        break;
                    case TYPE_TIMED: {
                        STATS.received(length);
                        long captureUs = ByteBuffer.wrap(buf, 0, 8).getLong();
                        // Video alone sets the baseline: it is the reference audio is aligned to.
                        STATS.arrivalJitter(clock.arrived(captureUs));
                        if (decoder != null) decoder.queue(buf, 8, length - 8, 0, captureUs);
                        break;
                    }
                    case TYPE_AUDIO_CONFIG: {
                        String[] parts = new String(buf, 0, length, StandardCharsets.US_ASCII).split(",");
                        if (audio != null) audio.release();
                        audio = new AudioPlayer(clock, Integer.parseInt(parts[0].trim()),
                                Integer.parseInt(parts[1].trim()));
                        break;
                    }
                    case TYPE_AV_OFFSET: {
                        String[] parts = new String(buf, 0, length, StandardCharsets.US_ASCII).split(",");
                        long ms = Long.parseLong(parts[0].trim());
                        clock.setAvOffsetNs(ms * 1_000_000L);
                        if (parts.length > 1 && parts[1].trim().equals("1")) settings.saveAvOffsetMs(ms);
                        Log.i(TAG, "audio/video offset " + ms + " ms" + (parts.length > 1 ? " persist=" + parts[1] : ""));
                        break;
                    }
                    case TYPE_AUDIO:
                        if (audio != null && length > 8) {
                            audio.enqueue(ByteBuffer.wrap(buf, 0, 8).getLong(), buf, 8, length - 8);
                        }
                        break;
                    default:
                        // Unknown packet types are skipped so newer senders stay compatible.
                        break;
                }
            }
        } finally {
            if (decoder != null) decoder.release();
            if (audio != null) audio.release();
        }
    }

    /** Per-second receive/decode counters, logged to logcat under the FireScreen tag. */
    static final class Stats {
        private int frames, rendered;
        private long bytes, waitNs, decodeUsMax, decodeUsTotal, gapNsMax, lastArrival, windowStart = System.nanoTime();
        private long lastShown, shownGapNsMax, jitterNsTotal, jitterNsMax, codecNsTotal, codecNsMax;
        private int jitterCount, codecCount;
        private int audioChunks;
        volatile long syncDelayNs, audioQueuedNs, audioOutputLatencyNs, audioArrivalLagNs;
        private long audioErrAbsTotal, audioErrAbsMax, audioPaddedNs, audioSkippedNs;

        /** Scheduling error of a chunk before correction; positive = would have played late. */
        synchronized void audioError(long ns) {
            audioChunks++;
            audioErrAbsTotal += Math.abs(ns);
            audioErrAbsMax = Math.max(audioErrAbsMax, Math.abs(ns));
        }

        synchronized void audioCorrection(long skippedNs, long paddedNs) {
            audioSkippedNs += skippedNs;
            audioPaddedNs += paddedNs;
        }

        /** How much later than the fastest frame this one arrived. */
        synchronized void arrivalJitter(long ns) {
            jitterNsTotal += ns;
            jitterNsMax = Math.max(jitterNsMax, ns);
            jitterCount++;
        }

        /** Time inside MediaCodec: queued input to available output. */
        synchronized void codecTime(long ns) {
            codecNsTotal += ns;
            codecNsMax = Math.max(codecNsMax, ns);
            codecCount++;
        }

        /** shownAtNs: when the frame is scheduled to appear on screen. */
        synchronized void shown(long shownAtNs) {
            if (lastShown != 0) shownGapNsMax = Math.max(shownGapNsMax, shownAtNs - lastShown);
            lastShown = shownAtNs;
        }

        synchronized void received(int length) {
            long now = System.nanoTime();
            if (lastArrival != 0) gapNsMax = Math.max(gapNsMax, now - lastArrival);
            lastArrival = now;
            frames++;
            bytes += length;
            maybeFlush(now);
        }

        synchronized void inputWait(long ns) {
            waitNs += ns;
        }

        synchronized void rendered(long decodeUs) {
            rendered++;
            decodeUsTotal += decodeUs;
            decodeUsMax = Math.max(decodeUsMax, decodeUs);
        }

        private void maybeFlush(long now) {
            if (now - windowStart < 1_000_000_000L) return;
            Log.i(TAG, String.format("stats rx=%d %.1fMbps maxgap=%dms shown maxgap=%dms jitter avg=%dms max=%dms codec avg=%dms max=%dms inputwait=%dms rendered=%d total avg=%dms max=%dms audio n=%d err avg=%dms max=%dms pad=%dms skip=%dms sync=%dms (arrival lag %dms, track queue %dms, output %dms)",
                    frames, bytes * 8 / 1e6, gapNsMax / 1_000_000, shownGapNsMax / 1_000_000,
                    jitterCount > 0 ? jitterNsTotal / jitterCount / 1_000_000 : 0, jitterNsMax / 1_000_000,
                    codecCount > 0 ? codecNsTotal / codecCount / 1_000_000 : 0, codecNsMax / 1_000_000, waitNs / 1_000_000, rendered,
                    rendered > 0 ? decodeUsTotal / rendered / 1000 : 0, decodeUsMax / 1000,
                    audioChunks, audioChunks > 0 ? audioErrAbsTotal / audioChunks / 1_000_000 : 0,
                    audioErrAbsMax / 1_000_000, audioPaddedNs / 1_000_000, audioSkippedNs / 1_000_000,
                    syncDelayNs / 1_000_000, audioArrivalLagNs / 1_000_000, audioQueuedNs / 1_000_000,
                    audioOutputLatencyNs / 1_000_000));
            audioChunks = 0;
            audioErrAbsTotal = audioErrAbsMax = audioPaddedNs = audioSkippedNs = 0;
            frames = rendered = jitterCount = codecCount = 0;
            jitterNsTotal = jitterNsMax = codecNsTotal = codecNsMax = 0;
            bytes = waitNs = decodeUsMax = decodeUsTotal = gapNsMax = shownGapNsMax = 0;
            windowStart = now;
        }
    }

    private void sendHello(Socket socket) throws IOException {
        byte[] body = (PROTOCOL_VERSION + "|" + settings.avOffsetMs() + "|" + settings.deviceName().replace('|', ' '))
                .getBytes(StandardCharsets.UTF_8);
        java.io.DataOutputStream out = new java.io.DataOutputStream(socket.getOutputStream());
        out.writeByte(TYPE_HELLO);
        out.writeInt(body.length);
        out.write(body);
        out.flush();
    }

    private static void closeQuietly(Socket s) {
        if (s == null) return;
        try {
            s.close();
        } catch (IOException ignored) {
        }
    }

    /**
     * Hardware H.264/HEVC decoder. Frames are presented at the sender's capture cadence (see
     * PlayoutClock), so Wi-Fi and capture jitter do not reach the screen.
     */
    private static final class Decoder {
        private final PlayoutClock clock;

        private final MediaCodec codec;
        private final Thread drain;
        private volatile boolean alive = true;
        /** captureUs -> nanoTime when queued, to measure time spent inside the codec. */
        private final java.util.concurrent.ConcurrentHashMap<Long, Long> queuedAt =
                new java.util.concurrent.ConcurrentHashMap<>();

        Decoder(Surface surface, String mime, int width, int height, int fps, PlayoutClock clock) throws IOException {
            this.clock = clock;
            MediaFormat format = MediaFormat.createVideoFormat(mime, width, height);
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, width * height);
            format.setInteger(MediaFormat.KEY_PRIORITY, 0); // real-time
            format.setInteger(MediaFormat.KEY_OPERATING_RATE, fps);
            format.setInteger("low-latency", 1); // honoured from Android 11, ignored before
            codec = MediaCodec.createDecoderByType(mime);
            codec.configure(format, surface, null, 0);
            codec.start();
            drain = new Thread(new Runnable() {
                @Override
                public void run() {
                    drainLoop();
                }
            }, "firescreen-drain");
            drain.start();
        }

        void queue(byte[] data, int offset, int length, int flags, long captureUs) {
            while (alive) {
                int index;
                long waitStart = System.nanoTime();
                try {
                    index = codec.dequeueInputBuffer(100_000);
                    STATS.inputWait(System.nanoTime() - waitStart);
                } catch (IllegalStateException e) {
                    return;
                }
                if (index < 0) continue;
                ByteBuffer input = codec.getInputBuffer(index);
                if (input == null) return;
                input.clear();
                if (length > input.capacity()) {
                    Log.w(TAG, "access unit larger than input buffer: " + length);
                    codec.queueInputBuffer(index, 0, 0, 0, 0);
                    return;
                }
                input.put(data, offset, length);
                if (flags == 0) {
                    queuedAt.put(captureUs, System.nanoTime());
                    if (TRACE) Log.i(TAG, "in  " + captureUs / 1000 + " " + length + "B" + (isIdr(data, offset, length) ? " IDR" : ""));
                }
                codec.queueInputBuffer(index, 0, length, captureUs, flags);
                return;
            }
        }

        private static boolean isIdr(byte[] d, int off, int len) {
            for (int i = off; i + 4 < off + len; i++) {
                if (d[i] != 0 || d[i + 1] != 0 || d[i + 2] != 1) continue;
                int avcType = d[i + 3] & 0x1f, hevcType = (d[i + 3] >> 1) & 0x3f;
                if (avcType == 5 || (hevcType >= 16 && hevcType <= 21)) return true; // trace label only
            }
            return false;
        }

        private void drainLoop() {
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            while (alive) {
                int index;
                try {
                    index = codec.dequeueOutputBuffer(info, 50_000);
                } catch (IllegalStateException e) {
                    return;
                }
                if (index < 0) continue;
                long now = System.nanoTime();
                Long queued = queuedAt.remove(info.presentationTimeUs);
                if (queued != null) {
                    STATS.codecTime(now - queued);
                    if (TRACE) Log.i(TAG, "out " + info.presentationTimeUs / 1000 + " codec=" + (now - queued) / 1_000_000 + "ms");
                }
                long due = clock.videoDueNs(info.presentationTimeUs);
                STATS.rendered((now - due) / 1000);
                if (due <= now || due - now > 500_000_000L) {
                    STATS.shown(now);
                    clock.videoShown(due, now);
                    codec.releaseOutputBuffer(index, true); // late (or clock jump): show now
                } else {
                    STATS.shown(due);
                    clock.videoShown(due, due);
                    codec.releaseOutputBuffer(index, due);
                }
            }
        }

        void release() {
            alive = false;
            try {
                drain.join(500);
            } catch (InterruptedException ignored) {
            }
            try {
                codec.stop();
            } catch (IllegalStateException ignored) {
            }
            codec.release();
        }
    }
}
