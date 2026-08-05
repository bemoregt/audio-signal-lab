//
//  SystemAudioSource.swift
//  AudioWaterfall
//

import AVFoundation
import ScreenCaptureKit

final class SystemAudioSource: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate {
    private(set) var isRunning = false

    private var stream: SCStream?
    private let converter = AudioFormatConverter()
    private var bufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private let audioQueue = DispatchQueue(label: "SystemAudioSource.audio")

    func start(bufferHandler: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        guard !isRunning else { return }
        self.bufferHandler = bufferHandler

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw AudioSourceError.screenRecordingPermissionDenied
        }
        guard let display = content.displays.first else {
            throw AudioSourceError.screenRecordingPermissionDenied
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 44100
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()

        self.stream = stream
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        let streamToStop = stream
        stream = nil
        bufferHandler = nil
        isRunning = false
        Task {
            try? await streamToStop?.stopCapture()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid else { return }
        guard let pcmBuffer = sampleBuffer.toAVAudioPCMBuffer() else { return }
        guard let converted = converter.convert(pcmBuffer) else { return }
        bufferHandler?(converted)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
    }
}

private extension CMSampleBuffer {
    /// Wraps the sample buffer's audio data without copying; the returned AVAudioPCMBuffer's
    /// deallocator retains the CMBlockBuffer so the underlying storage stays valid for the
    /// PCM buffer's lifetime rather than being freed when this function returns.
    func toAVAudioPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: asbd) else {
            return nil
        }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: &audioBufferList) { _ in
            _ = blockBuffer
        }
    }
}
