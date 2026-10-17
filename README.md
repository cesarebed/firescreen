# FireScreen

Use an Amazon Fire TV as a wireless display for your Mac: **extend** your desktop onto the TV as a
second monitor, or **mirror** your screen, with sound playing on the TV in sync with the picture.

- **Extend or mirror.** Extend adds the TV as a real second display (windows, Spaces, full screen);
  mirror shows the Mac's own screen.
- **Sound on the TV, in sync.** System audio plays on the TV, lined up with the frame captured at the
  same instant. The Mac is muted while streaming and restored afterwards.
- **Per-TV calibration.** A flash-and-beep test lets you correct the delay your TV or soundbar adds.
  The result is stored on the Fire TV, so it applies whichever Mac connects.
- **Menu bar app.** Start, stop, pick your TV (found automatically on the network), install the
  receiver, calibrate. A command line covers the same ground.
- **Low latency.** Hardware HEVC/H.264 on both ends and a custom TCP stream rather than HLS: about
  150 ms from Mac to TV on a home network.

FireScreen has two parts: a Mac app (Swift) and a small receiver app for the Fire TV (Java), which
you install over the network with adb.

> FireScreen is an independent project, not affiliated with or endorsed by Amazon or Apple.
> It relies on a private macOS API for the virtual display (see [Limitations](#limitations)).

## How it works

```
Mac                                                         Fire TV
virtual display ─▶ ScreenCaptureKit ─▶ VideoToolbox HEVC ─┐
                         │                                ├─ TCP :7878 ─▶ MediaCodec ─▶ screen
                         └──── system audio (PCM) ────────┘              AudioTrack ─▶ HDMI audio
                                                          shared playout clock keeps both in step
```

Every video frame and audio chunk carries its capture time. The receiver shows each frame on the
sender's cadence, a small fixed delay behind the fastest arrival, and schedules each audio chunk for
when its matching frame is on screen. [docs/DESIGN.md](docs/DESIGN.md) explains the choices and the
measurements behind them. [docs/PROTOCOL.md](docs/PROTOCOL.md) describes the wire format.

## Requirements

| | Tested | Expected to work |
|---|---|---|
| Mac | macOS 26.1, Apple M1 Pro | macOS 14 or later; Apple silicon recommended (hardware HEVC) |
| Fire TV | Fire TV Stick (AFTSS), Fire OS 7.7 | Fire OS 6 or later (Android 7.1+) |
| Network | Mac on 2.4 GHz, Fire TV on 5 GHz, same router | Same local network, no client isolation |

Build tools (no Xcode needed, the Command Line Tools are enough):

```bash
xcode-select --install
```

```bash
brew install openjdk@21
```

```bash
brew install --cask android-commandlinetools android-platform-tools
```

```bash
sdkmanager --sdk_root=/opt/homebrew/share/android-commandlinetools "platforms;android-34" "build-tools;36.0.0"
```

`android-commandlinetools` needs a Java runtime: if the cask complains, run
`export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home` first. Accept the
SDK licences when `sdkmanager` asks.

## Install

1. **Build everything** (receiver APK, then the Mac app with the APK inside):

   ```bash
   make all
   ```

   ```bash
   make install
   ```

   `make install` copies FireScreen.app to /Applications. Open it: a TV icon appears in the menu bar.

2. **Prepare the Fire TV** (once):
   - Settings > My Fire TV > About: select the device name 7 times to unlock **Developer options**.
   - Settings > My Fire TV > Developer options: turn on **ADB debugging**.
   - Note the TV's IP address: Settings > My Fire TV > About > Network.

3. **Install the receiver**: menu bar > **Install receiver on Fire TV…**, enter the IP address.
   The TV asks *Allow USB debugging?*: choose **Always allow from this computer** and **OK**.
   FireScreen opens on the TV and waits for your Mac. From the command line instead:

   ```bash
   make install-receiver HOST=192.168.1.20
   ```

4. **Grant macOS permissions** the first time you stream:
   - **Screen & System Audio Recording** (System Settings > Privacy & Security): turn on FireScreen.
     macOS may ask you to reopen the app.
   - **Local Network**: allow FireScreen to find devices on your network.

5. **Calibrate audio/video sync** for this TV: menu bar > **Calibrate audio/video sync…** (see below).

## Use

Open FireScreen on the TV (it is in *Your Apps & Channels*; FireScreen also opens it for you over
adb when it can), then from the menu bar:

| Menu item | What it does |
|---|---|
| Extend display to TV | Adds the TV as a second display, to the right of the Mac's screen |
| Mirror display on TV | Shows the Mac's main display on the TV |
| Stop | Ends the stream, removes the virtual display, restores the Mac's sound |
| Fire TV ▸ | Receivers found on the network; *Enter address…* for a manual IP |
| Film mode | Steadier motion for video, at about 70 ms more delay |
| Play sound on TV | Off: the sound stays on the Mac |
| Video codec ▸ | HEVC (default, less bandwidth) or H.264 |
| Calibrate audio/video sync… | Per-TV sync setup |
| Install receiver on Fire TV… | Installs or updates the receiver over adb |

To arrange where the TV sits relative to your Mac, use System Settings > Displays while streaming.

### Command line

The app's binary is also a command line tool:

```bash
alias firescreen=/Applications/FireScreen.app/Contents/MacOS/FireScreen
```

```bash
firescreen discover
```

```bash
firescreen stream --mode extend --smooth
```

```bash
firescreen calibrate
```

`firescreen --help` lists every command and option (`--host`, `--mode`, `--smooth`, `--no-audio`,
`--codec`, `--size`, `--fps`, `--bitrate`, `--hidpi`, `--stats`). Without `--host`, the command line
uses the receiver last chosen in the menu bar, or the first one it finds on the network. Ctrl-C stops
the stream and restores the Mac's sound.

## Calibrate audio/video sync

FireScreen already lines sound up with picture at the Fire TV's HDMI output: measured on the device,
the error is within a few milliseconds. What it cannot see is what happens after that: TVs delay the
picture for processing, and soundbars and receivers delay the sound. That offset differs from one TV
setup to another, so FireScreen lets you correct it once per TV:

1. Menu bar > **Calibrate audio/video sync…** (or `firescreen calibrate`).
2. The TV flashes white once a second with a beep, and a small panel opens on your Mac.
3. If you hear the beep **after** the flash, press **Audio earlier**; if **before**, **Audio later**.
   Keyboard: ← and →, with ⇧ for 50 ms steps.
4. When flash and beep coincide, press **Save for this TV**.

The offset is stored on the Fire TV. Run the calibration again if you change TV picture modes
(game mode usually lowers picture delay) or add or remove a soundbar.

## Testing

Self-tests need no devices:

```bash
make test
```

They cover the wire format, bitstream and audio conversion and option parsing on the Mac side, and
the shared playout clock on the receiver side.

End-to-end checks with real hardware:

1. **Test videos.** This writes a flash-and-beep sync clip and a motion clip (1080p, 24 fps), so
   nothing depends on copyrighted footage:

   ```bash
   make clips DIR=~/Movies/firescreen-tests
   ```

2. **Pipeline statistics.** Run a stream with `--stats` and play a clip full screen on the TV:

   ```bash
   firescreen stream --smooth --stats
   ```

   Each second the Mac prints frames captured, encoded and sent, bitrate, drops and audio packets.
   The receiver logs its side; read it with:

   ```bash
   adb logcat -s FireScreen
   ```

   On a healthy stream: `drop=0`, `shown maxgap` close to the content's frame interval (50 ms for
   24 fps on a 60 Hz TV in film mode), `audio err` within a few ms, `pad` and `skip` at 0.
3. **Sync by eye and ear.** Play the sync clip on the TV: flash and beep should coincide.
4. **Smoothness.** Play the motion clip: the bar should move at an even pace, without hitches.

## Troubleshooting

| Problem | Fix |
|---|---|
| No TV icon in the menu bar | On a Mac with a notch, a full menu bar hides icons behind it. Remove some items, or on macOS 26 manage them in System Settings > Menu Bar. |
| "Screen Recording permission missing" | Turn FireScreen on in System Settings > Privacy & Security > Screen & System Audio Recording, then start again. After rebuilding from source you may need to toggle it off and on. |
| Status says "waiting for receiver" | macOS is asking for Local Network access (allow it), or the TV is not reachable. |
| The TV is not listed under Fire TV ▸ | Open FireScreen on the TV; the Mac and TV must be on the same network. Use *Enter address…* as a fallback. |
| Install fails with "did not authorize" | Turn on ADB debugging on the TV, and accept *Allow USB debugging?* within a minute. |
| The TV shows the same picture as the Mac in Extend mode | macOS restored an old mirroring setup: turn mirroring off in System Settings > Displays. |
| Video from Netflix, Prime Video, Apple TV+ is black | Protected (DRM) video cannot be captured by any screen-capture app. |
| The Mac stays muted | If FireScreen quits unexpectedly it cannot restore the sound: unmute from the menu bar or keyboard. |
| Jerky motion | Turn on Film mode; prefer 5 GHz Wi-Fi for the Fire TV; check `--stats` for `drop` above 0. |

## Limitations

- **Private API.** The virtual display uses `CGVirtualDisplay`, a private CoreGraphics API also
  used by tools such as BetterDisplay. A macOS update can break it, and it rules out the Mac App
  Store. Mirror mode does not depend on it.
- **Unsigned build.** The app is ad-hoc signed when you build it. Since you build it yourself,
  Gatekeeper does not block it.
- **Local network only, unencrypted.** The receiver accepts any device on your network, and the
  stream is not encrypted. Use it on a network you trust.
- **One Mac at a time** per Fire TV, and one Fire TV per Mac.
- **Latency.** About 150 ms Mac to TV. Fine for presentations, video, a second screen for reference
  material; not for fast games. The Fire TV's video decoder always holds about one frame, which
  sets a floor.

## Project layout

```
sender/            Mac app and command line (Swift Package, no Xcode project)
  Sources/FireScreen/        menu bar, CLI, capture, encoding, session, calibration
  Sources/FireScreenCore/    pure logic: wire format, bitstream and PCM conversion, options
  Sources/FireScreenSelfTest/
  Sources/VirtualDisplay/    Objective-C wrapper for CGVirtualDisplay
  make-app.sh                builds FireScreen.app
receiver/          Fire TV app (plain Java, built with the Android SDK tools, no Gradle)
  build.sh, test.sh
docs/              design notes and protocol
```

## Contributing

Issues and pull requests are welcome. Please run `make test` before submitting. A report with
`--stats` output and `adb logcat -s FireScreen` lines makes a playback problem much easier to fix.

## License

[MIT](LICENSE)
