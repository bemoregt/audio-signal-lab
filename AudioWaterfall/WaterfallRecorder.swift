//
//  WaterfallRecorder.swift
//  AudioWaterfall
//

import AVFoundation
import SceneKit
import AppKit

/// Records the live SCNView (via periodic `snapshot()` calls) and the analyzer's audio
/// stream into a single .mov file using AVAssetWriter. Video and audio arrive on different
/// clocks (a wall-clock timer vs. a running audio sample count) — both are anchored to the
/// same `recordingStartHostTime` so they line up without needing frame-accurate sync.
final class WaterfallRecorder {
    enum RecorderError: Error {
        case cannotAddVideoInput
        case cannotAddAudioInput
        case writerFailed(Error?)
    }

    private(set) var isRecording = false

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private weak var sceneView: SCNView?
    private var frameTimer: Timer?
    private let frameRate: Int32 = 30

    private var recordingStartHostTime: CFTimeInterval = 0
    private var sessionStarted = false
    private var audioSampleCount: Int64 = 0
    private var audioSampleRate: Double = 44100

    func start(view: SCNView, audioFormat: AVAudioFormat, outputURL: URL) throws {
        guard !isRecording else { return }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let pixelSize = view.convertToBacking(view.bounds).size
        let width = max(2, Int(pixelSize.width))
        let height = max(2, Int(pixelSize.height))

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true

        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: pixelAttributes)

        guard writer.canAdd(vInput) else { throw RecorderError.cannotAddVideoInput }
        writer.add(vInput)

        var asbd = audioFormat.streamDescription.pointee
        var audioFormatDescription: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &audioFormatDescription
        )

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioFormat.sampleRate,
            AVNumberOfChannelsKey: audioFormat.channelCount,
            AVEncoderBitRateKey: 128_000
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: audioFormatDescription)
        aInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(aInput) else { throw RecorderError.cannotAddAudioInput }
        writer.add(aInput)

        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error)
        }

        assetWriter = writer
        videoInput = vInput
        audioInput = aInput
        pixelBufferAdaptor = adaptor
        sceneView = view
        audioSampleRate = audioFormat.sampleRate
        audioSampleCount = 0
        sessionStarted = false
        recordingStartHostTime = CACurrentMediaTime()
        isRecording = true

        let timer = Timer(timeInterval: 1.0 / Double(frameRate), repeats: true) { [weak self] _ in
            self?.captureFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    /// Called from the same audio callback that feeds the analyzer — a no-op unless a
    /// recording session is active.
    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        let pts = CMTime(seconds: recordingStartHostTime.distance(to: CACurrentMediaTime()), preferredTimescale: 600)
        guard let sampleBuffer = makeAudioSampleBuffer(from: buffer, presentationTime: pts) else { return }
        audioInput.append(sampleBuffer)
        audioSampleCount += Int64(buffer.frameLength)
    }

    func stop(completion: @escaping (URL?) -> Void) {
        guard isRecording, let writer = assetWriter else {
            completion(nil)
            return
        }
        isRecording = false
        frameTimer?.invalidate()
        frameTimer = nil
        sceneView = nil

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        let outputURL = writer.outputURL
        writer.finishWriting {
            completion(writer.status == .completed ? outputURL : nil)
        }
    }

    private func captureFrame() {
        guard isRecording, let writer = assetWriter, let vInput = videoInput,
              let adaptor = pixelBufferAdaptor, let view = sceneView else { return }

        let pts = CMTime(seconds: recordingStartHostTime.distance(to: CACurrentMediaTime()), preferredTimescale: 600)
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }

        guard vInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }

        var pixelBufferOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
        guard let pixelBuffer = pixelBufferOut else { return }

        render(view.snapshot(), into: pixelBuffer)
        adaptor.append(pixelBuffer, withPresentationTime: pts)
    }

    private func render(_ image: NSImage, into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: rect)
        NSGraphicsContext.current = previous
    }

    private func makeAudioSampleBuffer(from buffer: AVAudioPCMBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        var asbd = buffer.format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(buffer.format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer else { return nil }

        let listStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        )
        guard listStatus == noErr else { return nil }
        return sampleBuffer
    }
}
