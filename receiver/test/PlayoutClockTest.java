package io.firescreen.receiver;

/** Plain-JDK checks for PlayoutClock (no Android needed). Run with receiver/test.sh. */
public final class PlayoutClockTest {
    private static int checks, failures;

    private static void check(boolean ok, String message) {
        checks++;
        if (!ok) {
            failures++;
            System.out.println("FAIL: " + message);
        }
    }

    public static void main(String[] args) {
        long ms = 1_000_000L;

        // Baseline follows the fastest arrival: a capture time far in the past is "slower".
        PlayoutClock clock = new PlayoutClock();
        long nowUs = System.nanoTime() / 1000;
        long late = clock.arrived(nowUs - 80_000); // arrived 80 ms after capture
        check(late == 0, "first packet defines the baseline");
        long faster = clock.arrived(nowUs - 70_000 + (System.nanoTime() / 1000 - nowUs));
        check(faster <= 0, "a faster packet lowers the baseline");
        check(clock.arrived(System.nanoTime() / 1000 - 120_000) > 40 * ms, "a slower packet reports its lateness");

        // Due times: video = capture + baseline + playout (+ sync); audio adds video lateness and offset.
        PlayoutClock c = new PlayoutClock();
        c.setPlayoutDelayNs(50 * ms);
        long capture = System.nanoTime() / 1000;
        c.arrived(capture);
        long video = c.videoDueNs(capture);
        check(c.audioDueNs(capture) == video, "audio and video due together by default");
        c.setAvOffsetNs(30 * ms);
        check(c.audioDueNs(capture) - c.videoDueNs(capture) == 30 * ms, "positive offset plays audio later");
        c.setAvOffsetNs(-20 * ms);
        check(c.audioDueNs(capture) - c.videoDueNs(capture) == -20 * ms, "negative offset plays audio earlier");
        c.setAvOffsetNs(0);

        // Shared sync delay moves both streams, is clamped, and is given back when audio runs early.
        c.audioError(40 * ms);
        check(c.syncDelayNs() == 10 * ms, "lateness raises the shared delay by a quarter per chunk");
        check(c.videoDueNs(capture) - video == 10 * ms, "shared delay also delays video");
        for (int i = 0; i < 1000; i++) c.audioError(1_000 * ms);
        check(c.syncDelayNs() == 500 * ms, "shared delay is capped at 500 ms");
        long unused = c.releaseSyncDelay(40 * ms);
        check(c.syncDelayNs() == 490 * ms && unused == 0, "early audio gives back shared delay first");
        PlayoutClock zero = new PlayoutClock();
        check(zero.releaseSyncDelay(40 * ms) == 40 * ms, "with no shared delay, all earliness is left for padding");

        // Video lateness feeds audio (EMA), never negative.
        PlayoutClock v = new PlayoutClock();
        for (int i = 0; i < 200; i++) v.videoShown(0, 20 * ms);
        check(Math.abs(v.videoLateNs() - 20 * ms) < ms, "video lateness converges to the observed value");
        for (int i = 0; i < 200; i++) v.videoShown(100 * ms, 0);
        check(v.videoLateNs() >= 0 && v.videoLateNs() < ms, "frames shown early count as on time");

        System.out.println(failures == 0 ? "OK: " + checks + " checks passed" : "FAILED: " + failures + " of " + checks);
        System.exit(failures == 0 ? 0 : 1);
    }
}
