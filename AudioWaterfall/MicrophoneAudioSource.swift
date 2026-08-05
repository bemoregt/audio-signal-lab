//
//  MicrophoneAudioSource.swift
//  AudioWaterfall
//

import AVFoundation

final class MicrophoneAudioSource: AudioSource {
    private let engine = AVAudioEngine()
    private let converter = AudioFormatConverter()
    private(set) var isRunning = false

    func start(bufferHandler: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        guard !isRunning else { return }

        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
        guard granted else { throw AudioSourceError.microphonePermissionDenied }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converted = self.converter.convert(buffer) else { return }
            bufferHandler(converted)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }
}
