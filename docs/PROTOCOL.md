# FireScreen wire protocol, version 1

One TCP connection from the Mac (sender) to the Fire TV (receiver), port **7878**. The receiver
advertises itself with DNS-SD as `_firescreen._tcp` (instance name `FireScreen <model>`) and serves
one sender at a time.

Every packet, in both directions:

```
type     u8
length   u32, big-endian   (payload bytes)
payload  length bytes
```

Unknown types are skipped, so either side can add packet types without breaking the other.

## Receiver to sender

| Type | Name | Payload |
|---|---|---|
| 1 | HELLO | ASCII `protocolVersion|avOffsetMs|deviceName`, sent once right after accept |

`avOffsetMs` is the calibration stored on this TV. `deviceName` may contain `|`; only the first two
separators count.

## Sender to receiver

| Type | Name | Payload |
|---|---|---|
| 1 | CONFIG | ASCII `width,height,fps[,playoutDelayMs[,avc\|hevc]]`. Creates (or recreates) the video decoder. Defaults: 50 ms, `avc`. |
| 3 | CODEC | Parameter sets in Annex B: SPS + PPS (H.264), VPS + SPS + PPS (HEVC). Sent before the first frame and whenever they change. |
| 4 | TIMED FRAME | `captureTimeUs` (i64, big-endian) then one access unit in Annex B. |
| 2 | FRAME | One access unit in Annex B, no timestamp: the receiver stamps it on arrival. Legacy. |
| 6 | AUDIO CONFIG | ASCII `sampleRate,channels`. Creates (or recreates) the audio player. |
| 5 | AUDIO | `captureTimeUs` of the first sample (i64, big-endian), then interleaved signed 16-bit little-endian PCM. |
| 7 | AV OFFSET | ASCII `offsetMs,persist`. Positive plays audio later. `persist=1` stores it as this TV's calibration; `0` applies it to the current connection only. |

A normal session: connect, read HELLO, send CONFIG, CODEC (with the first keyframe), AUDIO CONFIG,
then TIMED FRAME and AUDIO packets interleaved as they are produced.

## Timing

`captureTimeUs` comes from the sender's capture clock: ScreenCaptureKit presentation timestamps,
the same host clock for video and audio. The receiver never compares the two machines' clocks
directly. It tracks the smallest `arrival - capture` it has seen (the clock offset plus the fastest
transit) and presents each frame at:

```
capture + baseline + playoutDelay + syncDelay
```

Audio is due at the same instant, plus the video decoder's measured lateness and the calibration
offset. See [DESIGN.md](DESIGN.md).

## Keyframes

The sender emits no periodic keyframes: TCP does not lose data. A keyframe goes out when a sender
connects, and when the sender drops frames under network congestion (frames are dropped only until
that keyframe).
