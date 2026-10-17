import AppKit
import AVFoundation
import Foundation

/// Generated test material, so no video files ship with the project.
enum TestClips {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    enum Kind {
        /// Each second: one white frame and a 1 kHz beep of exactly that frame, starting together.
        case sync
        /// A bar moving across a busy background with a frame counter: judges smoothness.
        case motion
    }

    /// The A/V sync clip: bundled in FireScreen.app, else generated once and cached. Get it before
    /// a session starts: writing it competes with the live encoder and can stall.
    static func syncClip() throws -> URL {
        if let bundled = Bundle.main.url(forResource: "firescreen-sync", withExtension: "mov") { return bundled }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.firescreen.sender", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sync-v1.mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            try write(.sync, seconds: 30, to: url)
        }
        return url
    }

    /// 1920x1080 at 24 fps, H.264 video plus 48 kHz stereo PCM audio.
    static func write(_ kind: Kind, seconds: Int, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let partial = url.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        let writer = try AVAssetWriter(outputURL: partial, fileType: .mov)
        let (width, height, fps, rate) = (1920, 1080, 24, 48_000)
        let samplesPerFrame = rate / fps

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw Failure(description: "cannot start writing: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: 2,
                                   interleaved: true)!

        let total = fps * seconds
        func appendVideo(_ i: Int) throws {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
            guard let pb = pixelBuffer else { throw Failure(description: "no pixel buffer at frame \(i)") }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
            draw(kind, frame: i, marker: i % fps == 0, in: ctx, width: width, height: height)
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        func appendAudio(_ i: Int) {
            // One frame's worth of samples; for the sync clip, a 1 kHz beep spanning each marker frame.
            var pcm = [Int16](repeating: 0, count: samplesPerFrame * 2)
            if kind == .sync && i % fps == 0 {
                for n in 0..<samplesPerFrame {
                    let v = Int16(sin(2 * Double.pi * 1000 * Double(n) / Double(rate)) * 20000)
                    pcm[n * 2] = v
                    pcm[n * 2 + 1] = v
                }
            }
            let bytes = pcm.count * 2
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                                               blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                               dataLength: bytes, flags: 0, blockBufferOut: &block)
            pcm.withUnsafeBytes {
                _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!,
                                                  offsetIntoDestination: 0, dataLength: bytes)
            }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block!, formatDescription: format.formatDescription,
                sampleCount: samplesPerFrame,
                presentationTimeStamp: CMTime(value: CMTimeValue(i * samplesPerFrame), timescale: CMTimeScale(rate)),
                packetDescriptions: nil, sampleBufferOut: &sample)
            audio.append(sample!)
        }

        // Feed whichever input is ready. AVAssetWriter interleaves the file and may hold one input
        // until the other catches up, so waiting on a fixed alternation can deadlock. Audio may run
        // up to two seconds ahead of video.
        var (videoIndex, audioIndex) = (0, 0)
        var lastProgress = Date()
        while videoIndex < total || audioIndex < total {
            var progressed = false
            while audioIndex < total, audioIndex <= videoIndex + 2 * fps, audio.isReadyForMoreMediaData {
                appendAudio(audioIndex)
                audioIndex += 1
                progressed = true
            }
            if videoIndex < total, video.isReadyForMoreMediaData {
                try appendVideo(videoIndex)
                videoIndex += 1
                progressed = true
            }
            if writer.status == .failed {
                throw Failure(description: "writer failed: \(String(describing: writer.error))")
            }
            if progressed {
                lastProgress = Date()
            } else if Date().timeIntervalSince(lastProgress) > 10 {
                throw Failure(description: "writer stalled at video frame \(videoIndex), audio frame \(audioIndex)")
            } else {
                usleep(1000)
            }
        }
        video.markAsFinished()
        audio.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw Failure(description: "writer finished with status \(writer.status.rawValue): \(String(describing: writer.error))")
        }
        try FileManager.default.moveItem(at: partial, to: url)
    }

    private static func draw(_ kind: Kind, frame i: Int, marker: Bool, in ctx: CGContext, width: Int, height: Int) {
        switch kind {
        case .sync:
            ctx.setFillColor(marker ? NSColor.white.cgColor : NSColor(white: 0.15, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        case .motion:
            let bands = 16
            for band in 0..<bands {
                let hue = CGFloat((band * 37 + i * 3) % 360) / 360
                ctx.setFillColor(NSColor(hue: hue, saturation: 0.6, brightness: 0.7, alpha: 1).cgColor)
                ctx.fill(CGRect(x: band * width / bands, y: 0, width: width / bands, height: height))
            }
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: (i * 16) % width, y: height / 4, width: 80, height: height / 2))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            ("\(i)" as NSString).draw(at: NSPoint(x: 60, y: 60), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 120, weight: .bold),
                .foregroundColor: NSColor.black,
            ])
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
