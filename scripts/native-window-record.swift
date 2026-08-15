import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

enum NativeWindowRecorderError: Error, CustomStringConvertible {
    case badArguments
    case displayUnavailable
    case noFrames
    case targetWindowUnavailable(CGWindowID)
    case targetWindowHasNoApplication
    case writerFailed(String)

    var description: String {
        switch self {
        case .badArguments:
            return "expected WINDOW_ID DURATION TRAILING_MARGIN OUTPUT_MOV"
        case .displayUnavailable:
            return "the target window is not on a capturable display"
        case .noFrames:
            return "ScreenCaptureKit produced no complete frames"
        case .targetWindowUnavailable(let windowID):
            return "window \(windowID) is not available to ScreenCaptureKit"
        case .targetWindowHasNoApplication:
            return "the target window has no owning application"
        case .writerFailed(let message):
            return "video writer failed: \(message)"
        }
    }
}

final class NativeWindowStreamWriter: NSObject, SCStreamOutput, SCStreamDelegate {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let sampleQueue = DispatchQueue(label: "dev.soyukke.satin.readme-recorder")
    private var firstPresentationTime: CMTime?
    private var frameCount = 0
    private var streamError: Error?

    init(outputURL: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: outputURL)
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 12_000_000,
                    AVVideoExpectedSourceFrameRateKey: 60,
                    AVVideoMaxKeyFrameIntervalKey: 120,
                ],
            ]
        )
        super.init()
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw NativeWindowRecorderError.writerFailed("video input is unsupported")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw NativeWindowRecorderError.writerFailed(
                writer.error?.localizedDescription ?? "startWriting returned false"
            )
        }
    }

    func addOutput(to stream: SCStream) throws {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid,
            CMSampleBufferGetImageBuffer(sampleBuffer) != nil
        else {
            return
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstPresentationTime == nil {
            firstPresentationTime = presentationTime
            writer.startSession(atSourceTime: presentationTime)
        }
        guard input.isReadyForMoreMediaData else {
            return
        }
        if input.append(sampleBuffer) {
            frameCount += 1
        } else if streamError == nil {
            streamError =
                writer.error
                ?? NativeWindowRecorderError.writerFailed("append returned false")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        sampleQueue.async { [weak self] in
            self?.streamError = error
        }
    }

    func finish(duration: Double) async throws {
        var preparationError: Error?
        sampleQueue.sync {
            if let streamError {
                preparationError = streamError
                return
            }
            guard let firstPresentationTime, frameCount > 0 else {
                preparationError = NativeWindowRecorderError.noFrames
                return
            }
            let endTime = CMTimeAdd(
                firstPresentationTime,
                CMTime(seconds: duration, preferredTimescale: 600)
            )
            writer.endSession(atSourceTime: endTime)
            input.markAsFinished()
        }
        if let preparationError {
            writer.cancelWriting()
            throw preparationError
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw NativeWindowRecorderError.writerFailed(
                writer.error?.localizedDescription ?? "finishWriting did not complete"
            )
        }
    }
}

@main
struct NativeWindowRecorder {
    static func main() async {
        do {
            try await record()
        } catch {
            FileHandle.standardError.write(Data("native-window-record: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func record() async throws {
        guard CommandLine.arguments.count == 5,
            let rawWindowID = UInt32(CommandLine.arguments[1]),
            let duration = Double(CommandLine.arguments[2]),
            duration > 0,
            let trailingMargin = Double(CommandLine.arguments[3]),
            trailingMargin >= 0
        else {
            throw NativeWindowRecorderError.badArguments
        }
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[4])
        let windowID = CGWindowID(rawWindowID)
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: false
        )
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw NativeWindowRecorderError.targetWindowUnavailable(windowID)
        }
        guard let application = window.owningApplication else {
            throw NativeWindowRecorderError.targetWindowHasNoApplication
        }
        guard
            let display = content.displays.max(by: {
                intersectionArea(window.frame, $0.frame) < intersectionArea(window.frame, $1.frame)
            }), intersectionArea(window.frame, display.frame) > 0
        else {
            throw NativeWindowRecorderError.displayUnavailable
        }

        let localX = max(0, window.frame.minX - display.frame.minX)
        let localY = max(0, window.frame.minY - display.frame.minY)
        let availableWidth = max(0, display.frame.width - localX)
        let availableHeight = max(0, display.frame.height - localY)
        let captureRect = CGRect(
            x: localX,
            y: localY,
            width: min(window.frame.width + trailingMargin, availableWidth),
            height: min(window.frame.height, availableHeight)
        )
        guard captureRect.width > 0, captureRect.height > 0 else {
            throw NativeWindowRecorderError.displayUnavailable
        }

        let filter = SCContentFilter(
            display: display,
            including: [application],
            exceptingWindows: []
        )
        let scale = max(CGFloat(filter.pointPixelScale), 1)
        let outputWidth = evenPixelCount(captureRect.width * scale)
        let outputHeight = evenPixelCount(captureRect.height * scale)
        let backgroundColor = CGColor(gray: 0, alpha: 1)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = captureRect
        configuration.width = outputWidth
        configuration.height = outputHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 8
        configuration.showsCursor = false
        configuration.backgroundColor = backgroundColor
        configuration.capturesAudio = false
        configuration.streamName = "Satin README demo"
        configuration.presenterOverlayPrivacyAlertSetting = .never
        if #available(macOS 14.2, *) {
            configuration.includeChildWindows = true
        }

        let streamWriter = try NativeWindowStreamWriter(
            outputURL: outputURL,
            width: outputWidth,
            height: outputHeight
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: streamWriter)
        try streamWriter.addOutput(to: stream)
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        try await stream.stopCapture()
        try await streamWriter.finish(duration: duration)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func evenPixelCount(_ value: CGFloat) -> Int {
        let rounded = max(2, Int(value.rounded()))
        return rounded.isMultiple(of: 2) ? rounded : rounded - 1
    }
}
