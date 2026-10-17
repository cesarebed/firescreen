import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures one display with ScreenCaptureKit, scaled to the stream size.
final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "firescreen.capture", qos: .userInteractive)

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
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
        config.capturesAudio = false
        config.preservesAspectRatio = true

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
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
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sample))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("capture stopped: \(error.localizedDescription)")
    }
}
