//
//  AudioSource.swift
//  AudioWaterfall
//

import AVFoundation

protocol AudioSource: AnyObject {
    var isRunning: Bool { get }
    func start(bufferHandler: @escaping (AVAudioPCMBuffer) -> Void) async throws
    func stop()
}

enum AudioSourceError: Error, LocalizedError {
    case microphonePermissionDenied
    case screenRecordingPermissionDenied
    case fileLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access was denied. Enable it in System Settings > Privacy & Security > Microphone."
        case .screenRecordingPermissionDenied:
            return "Screen Recording permission is required to capture system audio. Enable it in System Settings > Privacy & Security > Screen Recording, then relaunch AudioWaterfall."
        case .fileLoadFailed(let reason):
            return "Couldn't load audio file: \(reason)"
        }
    }
}
