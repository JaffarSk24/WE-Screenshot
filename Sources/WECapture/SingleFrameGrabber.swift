import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Takes one complete frame from an SCStream (the macOS 13 path, where
/// SCScreenshotManager does not exist). Every exit path stops the stream and
/// resumes the continuation exactly once.
final class SingleFrameGrabber: NSObject, SCStreamOutput, SCStreamDelegate {
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let displayID: UInt32
    private let queue = DispatchQueue(label: "WECapture.SingleFrameGrabber")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var finished = false
    private var stream: SCStream?

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, displayID: UInt32) {
        self.filter = filter
        self.configuration = configuration
        self.displayID = displayID
    }

    func grab(timeout: TimeInterval) async throws -> CGImage {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            lock.lock()
            self.stream = stream
            lock.unlock()

            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            } catch {
                finish(.failure(error))
                return
            }

            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(CaptureError.notResponding))
            }

            stream.startCapture { [weak self] error in
                if let error = error {
                    self?.finish(.failure(error))
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, isComplete(sampleBuffer) else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if let image = makeImage(from: pixelBuffer, fallbackDisplayID: displayID) {
            finish(.success(image))
        } else {
            finish(.failure(CaptureError.failed("Could not read the screen frame")))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(.failure(error))
    }

    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let first = attachments.first,
            let rawStatus = first[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        // The first frame after the stream starts may be tagged .started and
        // still carry the picture; on a screen where nothing moves it can be
        // the only frame with pixels.
        return (status == .complete || status == .started) && CMSampleBufferGetImageBuffer(sampleBuffer) != nil
    }

    private func finish(_ result: Result<CGImage, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let stream = self.stream
        self.stream = nil
        lock.unlock()

        guard let stream = stream else {
            continuation?.resume(with: result)
            return
        }
        // The answer is given only after the stream has really stopped: a
        // capture that starts while the previous stream is still closing, or
        // a process that quits in that moment, can leave the system capture
        // service stuck. The grabber stays alive through this closure, so a
        // late frame cannot reach a deallocated output.
        let resumeGate = OnceGate()
        stream.stopCapture { _ in
            _ = self
            if resumeGate.pass() { continuation?.resume(with: result) }
        }
        queue.asyncAfter(deadline: .now() + 2) {
            if resumeGate.pass() { continuation?.resume(with: result) }
        }
    }
}

/// Copies a BGRA pixel buffer into a CGImage, keeping the frame's colour space
/// (or the display's when the frame carries none).
func makeImage(from pixelBuffer: CVPixelBuffer, fallbackDisplayID: UInt32) -> CGImage? {
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
    guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

    // Copy the bytes: the IOSurface goes back to the stream once we return.
    let data = Data(bytes: base, count: bytesPerRow * height)
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }

    var colorSpace: CGColorSpace?
    if let attachments = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) {
        colorSpace = CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue()
    }
    let space = colorSpace
        ?? CGDisplayCopyColorSpace(fallbackDisplayID)
    let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)

    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: space,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}
