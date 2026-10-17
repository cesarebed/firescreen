import Foundation

public enum Media {
    public static let startCode: [UInt8] = [0, 0, 0, 1]

    /// VideoToolbox emits AVCC/HVCC (NAL units prefixed by a big-endian length); decoders on the
    /// receiver want Annex B (NAL units prefixed by start codes). Truncated input stops cleanly.
    public static func annexB(fromLengthPrefixed bytes: UnsafeRawBufferPointer, headerLength: Int) -> Data {
        var out = Data(capacity: bytes.count + 16)
        var offset = 0
        while offset + headerLength <= bytes.count {
            var nalLength = 0
            for i in 0..<headerLength { nalLength = (nalLength << 8) | Int(bytes[offset + i]) }
            offset += headerLength
            guard nalLength > 0, offset + nalLength <= bytes.count else { break }
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[offset..<(offset + nalLength)])
            offset += nalLength
        }
        return out
    }

    /// Converts float PCM to interleaved signed 16-bit little-endian, clamping to [-1, 1].
    /// `sample(frame, channel)` reads the source; a mono source is duplicated into every output channel.
    public static func int16Interleaved(frames: Int, sourceChannels: Int, outputChannels: Int,
                                        sample: (Int, Int) -> Float) -> Data {
        var out = Data(count: frames * outputChannels * 2)
        out.withUnsafeMutableBytes { raw in
            let pcm = raw.bindMemory(to: Int16.self)
            for frame in 0..<frames {
                for channel in 0..<outputChannels {
                    let v = max(-1, min(1, sample(frame, min(channel, sourceChannels - 1))))
                    pcm[frame * outputChannels + channel] = Int16(v * 32767).littleEndian
                }
            }
        }
        return out
    }
}
