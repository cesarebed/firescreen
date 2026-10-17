package io.firescreen.receiver;

/**
 * Maps sender capture timestamps to receiver presentation times, shared by video and audio so
 * both play against one reference.
 *
 * baseline = smallest (arrival - capture) seen: the clock offset between the two machines plus
 * the fastest transit. A frame is due at capture + baseline + playout delay, so anything arriving
 * up to "playout delay" later than the fastest packet is still on time.
 */
final class PlayoutClock {
    private volatile long playoutDelayNs = 50_000_000L;
    private long baselineNs;
    private boolean haveBaseline;
    /** How late video frames actually reach the screen versus their due time (EMA, >= 0). */
    private volatile long videoLateNs;
    /**
     * Extra delay applied to both video and audio when audio cannot be heard by the video due time
     * (the Fire Stick's audio output path is ~100+ ms). Sync costs latency: the slower path sets it.
     */
    private long syncDelayNs;
    private static final long MAX_SYNC_DELAY_NS = 500_000_000L;

    void setPlayoutDelayNs(long ns) {
        playoutDelayNs = ns;
    }

    /** Call with every timestamped packet as it arrives. Returns its lateness versus the fastest. */
    synchronized long arrived(long captureUs) {
        long delta = System.nanoTime() - captureUs * 1000;
        if (!haveBaseline || delta < baselineNs) {
            baselineNs = delta;
            haveBaseline = true;
        } else {
            // Creep up slowly so clock drift or a slower route cannot leave us permanently late.
            baselineNs += (delta - baselineNs) >> 9;
        }
        return delta - baselineNs;
    }

    synchronized long videoDueNs(long captureUs) {
        return captureUs * 1000 + baselineNs + playoutDelayNs + syncDelayNs;
    }

    /** Audio follows when video is really shown, which includes decoder lateness. */
    synchronized long audioDueNs(long captureUs) {
        return captureUs * 1000 + baselineNs + playoutDelayNs + syncDelayNs + videoLateNs;
    }

    /** Audio is late by lateNs even with a minimal queue: delay both streams to cancel it. */
    synchronized void audioError(long lateNs) {
        syncDelayNs = Math.max(0, Math.min(MAX_SYNC_DELAY_NS, syncDelayNs + lateNs / 4));
    }

    /** Audio is early by earlyNs: reduce the shared delay by up to that. Returns the part not absorbed. */
    synchronized long releaseSyncDelay(long earlyNs) {
        long released = Math.min(syncDelayNs, earlyNs / 4);
        syncDelayNs -= released;
        return syncDelayNs == 0 ? earlyNs - released : 0;
    }

    synchronized long baselineNs() {
        return baselineNs;
    }

    synchronized long syncDelayNs() {
        return syncDelayNs;
    }

    /** shownNs: when the frame was handed to the display, due or later. */
    void videoShown(long dueNs, long shownNs) {
        long late = Math.max(0, shownNs - dueNs);
        videoLateNs += (late - videoLateNs) >> 4;
    }

    long videoLateNs() {
        return videoLateNs;
    }
}
