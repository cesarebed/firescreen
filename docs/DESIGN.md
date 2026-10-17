# Design notes

Why FireScreen is built the way it is, and what was measured on the way. The reference hardware is
an Apple M1 Pro (macOS 26.1) and a Fire TV Stick AFTSS (MediaTek MT8695, Fire OS 7.7, 1 GB RAM)
over home Wi-Fi.

## Overall shape

- **Own stream, not HLS or Cast.** Segment-based streaming (HLS) adds seconds of delay, which rules
  out using the TV as a monitor. FireScreen sends each encoded frame over TCP as soon as it exists.
- **Hardware codecs on both ends.** VideoToolbox on the Mac (real-time mode, no B-frames, low-latency
  rate control) and MediaCodec on the Fire TV. Encoding takes about 10 ms per 1080p frame.
- **TCP rather than UDP.** On a home LAN, retransmission delays are small and rare. In exchange,
  nothing is ever lost, so there is no error concealment to write. When the network cannot keep up,
  the sender drops frames until the next keyframe rather than queueing them, so delay never builds.
- **PCM audio.** Uncompressed 48 kHz stereo is about 1.5 Mbps, small next to video. It adds no
  codec delay and needs no decoder.
- **No build systems.** The Mac side is a Swift package (Command Line Tools are enough) and the
  receiver is plain Java compiled with the SDK's `javac`, `d8`, `aapt2` and `apksigner`, with no
  Gradle or Android Gradle Plugin.

## Smooth motion: what mattered

Each item below was a measured cause of jerky playback, found by logging per-second statistics on
both ends (`--stats`, `adb logcat -s FireScreen`).

1. **Capture interval.** With ScreenCaptureKit's `minimumFrameInterval` equal to the display's
   refresh period, frames whose presentation jittered a fraction early were dropped and never
   recovered: a 24 fps clip arrived at 18-23 fps. Using half the stream frame period gives a
   steady 24/24.
2. **Virtual display refresh rate.** At 30 Hz, 24 fps content snapped to a 30 Hz grid with gaps up
   to 85 ms. At 60 Hz it follows the usual 3:2 cadence, like a TV.
3. **Paced presentation.** Showing frames as soon as they are decoded passes Wi-Fi and capture jitter
   straight to the screen. Frames now carry their capture time and are released with
   `releaseOutputBuffer(index, timestampNs)` on the original cadence. In film mode the shown gaps
   are exactly 33/50 ms for 24 fps content.
4. **No periodic keyframes.** After every IDR frame, the Fire Stick's MediaTek decoder held three
   frames back (about 150-175 ms), visible as a hitch every few seconds. Since TCP is lossless,
   keyframes are now sent only on connect and after a drop.

What did *not* help, all tried on the MediaTek decoder and reverted:

- Constrained Baseline profile.
- Rewriting the SPS VUI with `max_num_reorder_frames = 0`.
- Access unit delimiters after each frame.
- HEVC instead of H.264. It is still the default for its ~15-20% lower bitrate, but the decoder
  holds about one frame (~47 ms) either way.

A custom software decoder is not an option on this hardware: the platform's software H.264 decoder
is rated 10-40 fps at 1080p on its four Cortex-A53 cores, and multithreaded software decoding adds
frames of delay. The hardware decoder lives in the device's signed firmware.

## Audio/video sync

Audio and video share one `PlayoutClock` on the receiver:

- **Video** is due at `capture + baseline + playoutDelay + syncDelay`.
- **Audio** is due at the same instant, plus the video decoder's measured lateness (frames shown
  after their due time) and the per-TV calibration offset.
- `AudioPlayer` learns when a sample written now will actually be heard, from `AudioTrack`'s
  timestamp (the Fire Stick's output path is about 60 ms), and compares that with the chunk's due
  time.

The controller that closes the gap went through three versions, which is the useful lesson here:

1. **Correct every error by cutting or padding samples.** The Fire Stick's audio path is slower than
   the playout delay, so nearly every chunk was late and most audio was cut.
2. **Move the shared delay (video too) by the error.** This synchronises, but any audio that queued
   up was "compensated" by delaying video further. Latency only grew, past 400 ms.
3. **Current version:**
   - when audio is late, first drain audio queued beyond a 40 ms safety margin, in inaudible 3 ms
     steps, and move the shared delay only by what that cannot shed;
   - when audio is early, give shared delay back before padding with silence;
   - an explicit queue-level rule drains excess even when sync is already fine.

   Result: sync error 0-4 ms, no audible corrections, shared delay 30-100 ms depending on mode.

The receiver cannot see what the TV does after HDMI (picture processing, a soundbar's delay). That
is what the per-TV calibration corrects, and it is stored on the Fire TV itself.

## Latency budget (film mode, typical)

| Stage | ms |
|---|---|
| Capture + encode | ~15 |
| Wi-Fi transit and jitter allowance (playout delay) | 120 |
| Shared sync delay (audio path) | ~35 |
| Decoder hold (overlaps the playout delay) | ~47 |
| **Mac to TV** | **~150-170** |

Normal mode uses a 50 ms playout delay. The audio path then needs more shared delay (~100 ms), so
total latency ends up similar. With **Play sound on TV** off, normal mode is the lowest-latency
setting.
