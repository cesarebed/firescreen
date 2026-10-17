import FireScreenCore
import Foundation

var failures = 0
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL line \(line): \(message)")
    }
}

func bytes(_ data: Data) -> [UInt8] { [UInt8](data) }

// MARK: Wire

do {
    let packet = Wire.packet(.config, Data("1,2".utf8))
    check(bytes(packet) == [1, 0, 0, 0, 3, 0x31, 0x2C, 0x32], "packet framing: type, BE length, payload")

    let stamped = Wire.timestamped(micros: 0x0102030405060708, Data([0xAA]))
    check(bytes(stamped) == [1, 2, 3, 4, 5, 6, 7, 8, 0xAA], "timestamp is big-endian i64 before the payload")

    check(String(decoding: Wire.config(width: 1920, height: 1080, fps: 30, playoutDelayMs: 50, hevc: true),
                 as: UTF8.self) == "1920,1080,30,50,hevc", "config text")

    var reader = PacketReader()
    let two = Wire.packet(1, Data("1|-20|AFTSS".utf8)) + Wire.packet(9, Data())
    var got = reader.feed(two.prefix(3))
    check(got.isEmpty, "partial header yields nothing")
    got = reader.feed(two.dropFirst(3))
    check(got.count == 2, "both packets once complete")
    check(got.first?.type == 1 && ReceiverHello(payload: got[0].payload)
          == ReceiverHello(protocolVersion: 1, avOffsetMs: -20, deviceName: "AFTSS"), "hello parsed")
    check(got.last?.type == 9 && got.last?.payload.isEmpty == true, "empty payload packet")

    check(ReceiverHello(payload: Data("1|5|Living room | TV".utf8))?.deviceName == "Living room | TV",
          "device name may contain the separator")
    check(ReceiverHello(payload: Data("garbage".utf8)) == nil, "malformed hello rejected")
}

// MARK: Media

do {
    // Two NAL units with 4-byte lengths, then a truncated third that must be ignored.
    let avcc: [UInt8] = [0, 0, 0, 2, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0, 0, 0, 9, 0x65]
    let annexB = avcc.withUnsafeBytes { Media.annexB(fromLengthPrefixed: $0, headerLength: 4) }
    check(bytes(annexB) == [0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68], "AVCC to Annex B, truncated tail dropped")

    let short: [UInt8] = [0, 3, 1, 2, 3]
    let converted = short.withUnsafeBytes { Media.annexB(fromLengthPrefixed: $0, headerLength: 2) }
    check(bytes(converted) == [0, 0, 0, 1, 1, 2, 3], "2-byte length prefixes")

    let stereo: [[Float]] = [[0, 1, -1, 2], [0.5, -0.5, 0, -2]]
    let pcm = Media.int16Interleaved(frames: 4, sourceChannels: 2, outputChannels: 2) { stereo[$1][$0] }
    let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Int16(littleEndian: $0) }
    check(samples == [0, 16383, 32767, -16383, -32767, 0, 32767, -32767], "float to s16, interleaved, clamped")

    let mono = Media.int16Interleaved(frames: 2, sourceChannels: 1, outputChannels: 2) { f, _ in f == 0 ? 0.5 : -0.5 }
    let monoSamples = mono.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    check(monoSamples == [16383, 16383, -16383, -16383], "mono duplicated into both channels")
}

// MARK: Options

do {
    let defaults = try StreamOptions.parse([])
    check(defaults.mode == .extend && defaults.audio && defaults.hevc && !defaults.smooth && defaults.host == nil,
          "defaults: extend, audio on TV, HEVC, no fixed host")
    check(defaults.playoutDelayMs == 50, "default playout delay")

    let o = try StreamOptions.parse(["--host", "10.0.0.5", "--mode", "mirror", "--smooth", "--no-audio",
                                     "--codec", "h264", "--size", "1280x720", "--fps", "60", "--bitrate", "12.5"])
    check(o.host == "10.0.0.5" && o.mode == .mirror && o.smooth && !o.audio && !o.hevc, "flags")
    check(o.width == 1280 && o.height == 720 && o.fps == 60 && o.bitrateMbps == 12.5, "numbers")
    check(o.playoutDelayMs == 120, "smooth playout delay")

    for bad in [["--mode", "sideways"], ["--size", "big"], ["--fps"], ["--codec", "vp9"], ["--nope"], ["--port", "x"]] {
        check((try? StreamOptions.parse(bad)) == nil, "rejects \(bad)")
    }
} catch {
    check(false, "unexpected error \(error)")
}

print(failures == 0 ? "OK: \(checks) checks passed" : "FAILED: \(failures) of \(checks) checks")
exit(failures == 0 ? 0 : 1)
