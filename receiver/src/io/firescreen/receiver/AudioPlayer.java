package io.firescreen.receiver;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTimestamp;
import android.media.AudioTrack;
import android.os.Build;
import android.util.Log;

import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * Plays the sender's PCM so each chunk becomes audible when the video frame captured at the same
 * instant is on screen. AudioTrack's timestamp tells when a written frame will actually play.
 * When late, audio queued beyond a safety margin is drained first; only lateness the audio path
 * cannot shed moves the shared delay, which shifts video too. When early, that shared delay is
 * given back before silence is inserted. So latency settles at the slower path's real minimum.
 */
final class AudioPlayer {
    private static final String TAG = "FireScreen";
    /**
     * Small errors are cancelled smoothly by shifting the shared playout delay (PlayoutClock).
     * Only jumps beyond this are corrected in the sample stream, which is audible.
     */
    private static final long TOLERANCE_NS = 60_000_000L;
    /** Errors this small are left alone: well below the ~20 ms where lip sync becomes noticeable. */
    private static final long DEADBAND_NS = 5_000_000L;
    /** Largest gradual cut per chunk when draining excess queue. */
    private static final long STEP_NS = 3_000_000L;
    /** Audio kept queued in the track to ride out network and scheduling jitter without underruns. */
    private static final long MIN_QUEUE_NS = 40_000_000L;
    /** Queue above MIN_QUEUE_NS by more than this is drained even when sync is fine. */
    private static final long QUEUE_SLACK_NS = 20_000_000L;
    /** Beyond this the stream jumped (pause, reconnect): resynchronise instead of stretching. */
    private static final long RESYNC_NS = 1_000_000_000L;

    private static final class Chunk {
        final long captureUs;
        final byte[] pcm;

        Chunk(long captureUs, byte[] pcm) {
            this.captureUs = captureUs;
            this.pcm = pcm;
        }
    }

    private final PlayoutClock clock;
    private final int sampleRate;
    private final int bytesPerFrame;
    private final AudioTrack track;
    private final ArrayBlockingQueue<Chunk> queue = new ArrayBlockingQueue<>(256);
    private final Thread thread;
    private final AudioTimestamp timestamp = new AudioTimestamp();
    private volatile boolean alive = true;
    private long framesWritten;
    /** Output latency beyond the track buffer (mixer + HAL + HDMI), learned while playing. */
    private long outputLatencyNs = 40_000_000L;
    private long lastQueuedNs;

    AudioPlayer(PlayoutClock clock, int sampleRate, int channels) {
        this.clock = clock;
        this.sampleRate = sampleRate;
        this.bytesPerFrame = 2 * channels;
        int channelMask = channels == 1 ? AudioFormat.CHANNEL_OUT_MONO : AudioFormat.CHANNEL_OUT_STEREO;
        int minBuffer = AudioTrack.getMinBufferSize(sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT);
        // ~120 ms of room: the queue is held near MIN_QUEUE_NS, the rest absorbs bursts.
        int bufferBytes = Math.max(minBuffer * 2, sampleRate * bytesPerFrame * 12 / 100);

        AudioTrack.Builder builder = new AudioTrack.Builder()
                .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build())
                .setAudioFormat(new AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(channelMask)
                        .build())
                .setBufferSizeInBytes(bufferBytes)
                .setTransferMode(AudioTrack.MODE_STREAM);
        if (Build.VERSION.SDK_INT >= 26) builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY);
        track = builder.build();
        track.play();

        thread = new Thread(new Runnable() {
            @Override
            public void run() {
                playLoop();
            }
        }, "firescreen-audio");
        thread.setPriority(Thread.MAX_PRIORITY);
        thread.start();
    }

    /** Called on the network thread; never blocks it. */
    void enqueue(long captureUs, byte[] data, int offset, int length) {
        byte[] pcm = new byte[length - length % bytesPerFrame];
        System.arraycopy(data, offset, pcm, 0, pcm.length);
        if (!queue.offer(new Chunk(captureUs, pcm))) {
            queue.poll(); // backlog: the oldest audio is the most out of date
            queue.offer(new Chunk(captureUs, pcm));
        }
    }

    private void playLoop() {
        while (alive) {
            Chunk chunk;
            try {
                chunk = queue.poll(100, TimeUnit.MILLISECONDS);
            } catch (InterruptedException e) {
                return;
            }
            if (chunk == null) continue;

            long due = clock.audioDueNs(chunk.captureUs);
            long playAt = nextFramePlaysAtNs();
            long error = playAt - due; // > 0: this chunk would play late

            int skipBytes = 0;
            if (Math.abs(error) > RESYNC_NS) {
                if (error > 0) {
                    StreamServer.STATS.audioCorrection(error, 0);
                    continue; // hopelessly late: drop and let the next chunk resync
                }
                error = -RESYNC_NS; // far in the future: pad at most a second
            }
            StreamServer.STATS.audioError(error);

            if (lastQueuedNs > MIN_QUEUE_NS + QUEUE_SLACK_NS && error <= DEADBAND_NS) {
                // Queue above target with sync already fine: shed a little. The audio then runs
                // early, which hands the shared delay back, so both settle at the true minimum.
                int cutFrames = (int) Math.min(STEP_NS * sampleRate / 1_000_000_000L,
                        chunk.pcm.length / bytesPerFrame / 2);
                skipBytes = cutFrames * bytesPerFrame;
                StreamServer.STATS.audioCorrection((long) cutFrames * 1_000_000_000L / sampleRate, 0);
            } else if (error > DEADBAND_NS) {
                // Late. First drain audio queued beyond the safety margin: that is latency we
                // added ourselves. Small steps are inaudible; big jumps are cut at once.
                long reducible = Math.max(0, lastQueuedNs - MIN_QUEUE_NS);
                long cut = Math.min(Math.min(error, reducible), error > TOLERANCE_NS ? error : STEP_NS);
                // Never drop a whole chunk: the track must keep receiving data or it stalls.
                int cutFrames = (int) Math.min(cut * sampleRate / 1_000_000_000L, chunk.pcm.length / bytesPerFrame / 2);
                skipBytes = cutFrames * bytesPerFrame;
                long cutNs = (long) cutFrames * 1_000_000_000L / sampleRate;
                StreamServer.STATS.audioCorrection(cutNs, 0);
                // Lateness the audio path cannot shed moves the shared delay (video too).
                if (error - cutNs > DEADBAND_NS) clock.audioError(error - cutNs);
            } else if (error < -DEADBAND_NS) {
                // Early. Give back shared delay first (lower latency), then pad with silence.
                long unused = clock.releaseSyncDelay(-error);
                if (unused > TOLERANCE_NS) {
                    writeSilence(unused);
                    StreamServer.STATS.audioCorrection(0, unused);
                }
            }
            StreamServer.STATS.syncDelayNs = clock.syncDelayNs();
            StreamServer.STATS.audioQueuedNs = lastQueuedNs;
            StreamServer.STATS.audioOutputLatencyNs = outputLatencyNs;
            StreamServer.STATS.audioArrivalLagNs = System.nanoTime() - (chunk.captureUs * 1000 + clock.baselineNs());

            int length = chunk.pcm.length - skipBytes;
            if (length > 0) {
                int written = track.write(chunk.pcm, skipBytes, length); // blocking
                if (written > 0) framesWritten += written / bytesPerFrame;
            }
        }
    }

    /** When the next frame written to the track will reach the speaker, in System.nanoTime(). */
    private long nextFramePlaysAtNs() {
        long now = System.nanoTime();
        long queued = Math.max(0, framesWritten - (track.getPlaybackHeadPosition() & 0xffffffffL));
        lastQueuedNs = queued * 1_000_000_000L / sampleRate;
        // Earliest possible: everything still in the track buffer, then the output path.
        long floor = now + queued * 1_000_000_000L / sampleRate + outputLatencyNs;
        if (queued > 0 && track.getTimestamp(timestamp) && timestamp.framePosition > 0) {
            long extrapolated = timestamp.nanoTime
                    + (framesWritten - timestamp.framePosition) * 1_000_000_000L / sampleRate;
            // While playing steadily the timestamp is exact; learn the output latency from it.
            long observed = extrapolated - (floor - outputLatencyNs);
            if (observed > 0 && observed < 500_000_000L) outputLatencyNs += (observed - outputLatencyNs) >> 4;
            return Math.max(extrapolated, floor - outputLatencyNs);
        }
        // Starting, or after an underrun (timestamp is stale): fall back to the learned latency.
        return floor;
    }

    private void writeSilence(long ns) {
        long frames = ns * sampleRate / 1_000_000_000L;
        byte[] silence = new byte[(int) Math.min(frames * bytesPerFrame, sampleRate * bytesPerFrame)];
        int written = track.write(silence, 0, silence.length);
        if (written > 0) framesWritten += written / bytesPerFrame;
    }

    void release() {
        alive = false;
        thread.interrupt();
        try {
            thread.join(500);
        } catch (InterruptedException ignored) {
        }
        try {
            track.stop();
        } catch (IllegalStateException e) {
            Log.w(TAG, "audio stop: " + e.getMessage());
        }
        track.release();
    }
}
