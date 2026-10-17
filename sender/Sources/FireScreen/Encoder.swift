import CoreMedia
import Foundation
import VideoToolbox

/// Hardware H.264/HEVC encoder tuned for interactive latency: real-time, no B-frames,
/// low-latency rate control. Emits Annex B access units.
final class Encoder {
    /// (accessUnit, isKeyframe, capture time)
    var onFrame: ((Data, Bool, CMTime) -> Void)?
    /// SPS + PPS in Annex B, emitted whenever they change.
    var onParameterSets: ((Data) -> Void)?

    private var session: VTCompressionSession?
    private var forceKeyframe = true
    private var lastParameterSets: Data?
    private static let startCode: [UInt8] = [0, 0, 0, 1]

    private let hevc: Bool

    init(width: Int, height: Int, fps: Int, bitrateMbps: Double, hevc: Bool) throws {
        self.hevc = hevc
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        var created: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        if status != noErr && hevc { // low-latency rate control is not available for every codec
            status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        }
        guard status == noErr, let session = created else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate failed"])
        }
        self.session = session

        let bitrate = Int(bitrateMbps * 1_000_000)
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel:
                hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            // No periodic keyframes: TCP never loses data, and each IDR stalls the Fire Stick's
            // decoder ~150 ms. Keyframes are forced on connect and after a dropped frame instead.
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Int32.max,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            // Cap bursts at 1.5x the average over one second so a busy frame cannot flood Wi-Fi.
            kVTCompressionPropertyKey_DataRateLimits: [bitrate * 3 / 2 / 8, 1] as CFArray,
        ]
        for (key, value) in properties {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    func requestKeyframe() {
        forceKeyframe = true
    }

    /// The next keyframe re-announces SPS/PPS, for a receiver that just (re)connected.
    func resetParameterSets() {
        lastParameterSets = nil
        forceKeyframe = true
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        var options: CFDictionary?
        if forceKeyframe {
            forceKeyframe = false
            options = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }
        let started = DispatchTime.now().uptimeNanoseconds
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: options, infoFlagsOut: nil) {
            [weak self] status, _, sample in
            guard status == noErr, let sample else { return }
            Stats.shared.encoded(ms: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            self?.handle(sample)
        }
    }

    private func handle(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample) else { return }

        let keyframe = Self.isKeyframe(sample)
        var accessUnit = Data()

        // SPS/PPS go out-of-band only when they change: repeating them in-band on every keyframe
        // makes the Fire Stick's MediaTek decoder reinitialise (120-175 ms stall, dropped frames).
        if keyframe, let parameterSets = Self.parameterSets(format, hevc: hevc), parameterSets != lastParameterSets {
            lastParameterSets = parameterSets
            onParameterSets?(parameterSets)
        }

        var headerLength: Int32 = 4
        _ = Self.parameterSet(format, hevc: hevc, index: 0, pointer: nil, size: nil, count: nil,
                              headerLength: &headerLength)

        var totalLength = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength, dataPointerOut: &pointer) == noErr,
              let pointer else { return }

        // AVCC (length-prefixed NAL units) -> Annex B (start-code-prefixed).
        let bytes = UnsafeRawPointer(pointer)
        var offset = 0
        let prefix = Int(headerLength)
        while offset + prefix <= totalLength {
            var nalLength = 0
            for i in 0..<prefix {
                nalLength = (nalLength << 8) | Int(bytes.load(fromByteOffset: offset + i, as: UInt8.self))
            }
            offset += prefix
            guard offset + nalLength <= totalLength else { break }
            accessUnit.append(contentsOf: Self.startCode)
            accessUnit.append(bytes.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: nalLength)
            offset += nalLength
        }
        onFrame?(accessUnit, keyframe, CMSampleBufferGetPresentationTimeStamp(sample))
    }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]], let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    private static func parameterSets(_ format: CMFormatDescription, hevc: Bool) -> Data? {
        var count = 0
        guard parameterSet(format, hevc: hevc, index: 0, pointer: nil, size: nil, count: &count,
                           headerLength: nil) == noErr else { return nil }
        var result = Data()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard parameterSet(format, hevc: hevc, index: index, pointer: &pointer, size: &size, count: nil,
                               headerLength: nil) == noErr, let pointer else { return nil }
            result.append(contentsOf: startCode)
            result.append(pointer, count: size)
        }
        return result
    }

    /// H.264: SPS, PPS. HEVC: VPS, SPS, PPS.
    private static func parameterSet(_ format: CMFormatDescription, hevc: Bool, index: Int,
                                     pointer: UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
                                     size: UnsafeMutablePointer<Int>?, count: UnsafeMutablePointer<Int>?,
                                     headerLength: UnsafeMutablePointer<Int32>?) -> OSStatus {
        hevc
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: pointer, parameterSetSizeOut: size,
                parameterSetCountOut: count, nalUnitHeaderLengthOut: headerLength)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: pointer, parameterSetSizeOut: size,
                parameterSetCountOut: count, nalUnitHeaderLengthOut: headerLength)
    }
}
