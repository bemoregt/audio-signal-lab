//
//  FileAudioSource.swift
//  AudioWaterfall
//

import AVFoundation

final class FileAudioSource: AudioSource {
    var fileURL: URL?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let converter = AudioFormatConverter()
    private(set) var isRunning = false
    private var accessedURL: URL?

    func start(bufferHandler: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        guard !isRunning else { return }
        guard let fileURL else {
            throw AudioSourceError.fileLoadFailed("No file selected.")
        }

        guard fileURL.startAccessingSecurityScopedResource() else {
            throw AudioSourceError.fileLoadFailed("Couldn't access the selected file.")
        }
        accessedURL = fileURL

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            fileURL.stopAccessingSecurityScopedResource()
            accessedURL = nil
            throw AudioSourceError.fileLoadFailed(error.localizedDescription)
        }

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)

        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: engine.mainMixerNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let self, let converted = self.converter.convert(buffer) else { return }
            bufferHandler(converted)
        }

        engine.prepare()
        try engine.start()

        playerNode.scheduleFile(file, at: nil, completionHandler: nil)
        playerNode.play()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        playerNode.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
        engine.disconnectNodeOutput(playerNode)
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        isRunning = false
    }
}
