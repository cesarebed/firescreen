import CoreMedia
import FireScreenCore
import Foundation
import ScreenCaptureKit

/// Captures one display, plus system audio, with ScreenCaptureKit. Video is scaled to the
/// stream size. Audio and video timestamps share the host clock, which is what keeps them in sync.
final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate {
    static let audioSampleRate = 48_000
    static let audioChannels = 2

    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// (interleaved signed 16-bit little-endian PCM, capture time of its first sample)
    var onAudio: ((Data, CMTime) -> Void)?
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "firescreen.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "firescreen.audio", qos: .userInteractive)

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, audio: Bool) async throws {
        let display = try await Self.findDisplay(displayID)

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        // Half the stream frame period: an interval equal to the display's refresh period makes
        // ScreenCaptureKit drop video frames whose presentation jitters a fraction early.
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.queueDepth = 4
        config.showsCursor = true
        config.preservesAspectRatio = true
        config.capturesAudio = audio
        config.sampleRate = Self.audioSampleRate
        config.channelCount = Self.audioChannels
        config.excludesCurrentProcessAudio = true

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if audio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    /// A just-created virtual display can take a moment to show up in shareable content.
    private static func findDisplay(_ id: CGDirectDisplayID) async throws -> SCDisplay {
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let display = content.displays.first(where: { $0.displayID == id }) { return display }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw NSError(domain: "FireScreen", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "display \(id) not available to ScreenCaptureKit"])
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if sample.isValid, let pcm = Self.int16Interleaved(sample) {
                onAudio?(pcm, CMSampleBufferGetPresentationTimeStamp(sample))
            }
            return
        }
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sample))
    }

    /// ScreenCaptureKit delivers 32-bit float PCM, usually one buffer per channel.
    private static func int16Interleaved(_ sample: CMSampleBuffer) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else { return nil }
        let frames = CMSampleBufferGetNumSamples(sample)
        let channels = Int(asbd.mChannelsPerFrame)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let listMemory = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { listMemory.deallocate() }
        let list = listMemory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr
        else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(list)

        func sampleAt(_ frame: Int, _ channel: Int) -> Float {
            interleaved
                ? buffers[0].mData!.assumingMemoryBound(to: Float.self)[frame * channels + channel]
                : buffers[channel].mData!.assumingMemoryBound(to: Float.self)[frame]
        }

        return Media.int16Interleaved(frames: frames, sourceChannels: channels, outputChannels: audioChannels,
                                      sample: sampleAt)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("capture stopped: \(error.localizedDescription)")
    }
}
