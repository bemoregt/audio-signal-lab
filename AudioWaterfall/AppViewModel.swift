//
//  AppViewModel.swift
//  AudioWaterfall
//

import AppKit
import AVFoundation
import Combine
import Foundation
import SceneKit
import UniformTypeIdentifiers

enum AudioSourceKind: String, CaseIterable, Identifiable {
    case microphone = "Microphone"
    case file = "File"
    case systemAudio = "System Audio"

    var id: String { rawValue }
}

enum DisplayMode: String, CaseIterable, Identifiable {
    case waterfall3D = "3D Waterfall"
    case spectrogram2D = "2D Spectrogram"

    var id: String { rawValue }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var colormap: Colormap = .turboLike
    @Published var backgroundColorOption: BackgroundColorOption = .black
    @Published var selectedSource: AudioSourceKind = .microphone
    @Published var selectedFileURL: URL?
    @Published var resolution: SpectrumResolution = .ultra {
        didSet { applyResolution() }
    }
    @Published var logScaleEnabled = true {
        didSet { analyzer.logScaleEnabled = logScaleEnabled }
    }
    @Published var hannWindowEnabled = true {
        didSet { analyzer.hannWindowEnabled = hannWindowEnabled }
    }
    @Published var highPassFilterEnabled = true {
        didSet { analyzer.highPassFilterEnabled = highPassFilterEnabled }
    }
    @Published var cameraViewpoint: CameraViewpoint = .standard
    @Published var displayMode: DisplayMode = .waterfall3D
    @Published private(set) var isRecording = false

    @Published private(set) var history: SpectrumHistory
    // The 2D spectrogram needs far more time resolution than the 3D waterfall's 32-deep
    // mesh (which would look absurdly long if stretched that far) — a separate, longer
    // ring buffer keeps the two views' time axes independent.
    @Published private(set) var spectrogramHistory: SpectrumHistory
    // 512 (not 1024) — measured ~37ms/frame to build the spectrogram image at this size in
    // a debug build, comfortably under the ~93ms interval between real spectrum updates.
    // 1024 measured ~76ms/frame: technically keeps up on average but leaves little margin
    // before other main-thread work causes visible stutter.
    private let spectrogramTimeSteps = 512

    private let micSource = MicrophoneAudioSource()
    private let fileSource = FileAudioSource()
    private let systemAudioSource = SystemAudioSource()
    private let analyzer = SpectrumAnalyzer()
    private let recorder = WaterfallRecorder()
    private var pushTimer: Timer?
    private var activeSource: AudioSource?

    // Set by ContentView via WaterfallSceneView's onCreateView callback once the SCNView
    // exists — needed so recording can grab frames via SCNView.snapshot().
    weak var sceneView: SCNView?

    init() {
        // Can't read `self.resolution` before `history` is assigned, so use the same
        // static default directly instead.
        history = SpectrumHistory(timeSteps: 32, binCount: SpectrumResolution.ultra.binCount)
        spectrogramHistory = SpectrumHistory(timeSteps: spectrogramTimeSteps, binCount: SpectrumResolution.ultra.binCount)
        analyzer.visualBinCount = SpectrumResolution.ultra.binCount
    }

    /// Resolution changes swap in a fresh SpectrumHistory (its row size is fixed at
    /// construction) — the waterfall briefly starts blank at the new resolution rather
    /// than trying to resample old rows into the new bin count.
    private func applyResolution() {
        analyzer.visualBinCount = resolution.binCount
        history = SpectrumHistory(timeSteps: history.timeSteps, binCount: resolution.binCount)
        spectrogramHistory = SpectrumHistory(timeSteps: spectrogramTimeSteps, binCount: resolution.binCount)
    }

    func start() {
        guard !isRunning else { return }
        errorMessage = nil

        let source: AudioSource
        switch selectedSource {
        case .microphone:
            source = micSource
        case .file:
            guard let selectedFileURL else {
                errorMessage = "Choose a file first."
                return
            }
            fileSource.fileURL = selectedFileURL
            source = fileSource
        case .systemAudio:
            source = systemAudioSource
        }
        activeSource = source

        Task {
            do {
                try await source.start { [weak self] buffer in
                    self?.analyzer.process(buffer: buffer)
                    if self?.isRecording == true {
                        self?.recorder.appendAudio(buffer)
                    }
                }
                isRunning = true
                pushTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    // Timer's closure type isn't statically MainActor-isolated, but this
                    // timer is always scheduled from (and fires on) the main run loop.
                    MainActor.assumeIsolated {
                        guard let self, let spectrum = self.analyzer.consumeLatest() else { return }
                        self.history.push(spectrum)
                        self.spectrogramHistory.push(spectrum)
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
                activeSource = nil
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        if isRecording { stopRecording() }
        activeSource?.stop()
        activeSource = nil
        pushTimer?.invalidate()
        pushTimer = nil
        isRunning = false
    }

    /// Prompts for a save location, then starts writing the SCNView's frames and the live
    /// audio to a .mov file. Requires audio to already be running (see `sceneView`, `isRunning`).
    func startRecording() {
        guard !isRecording, isRunning, let sceneView else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "AudioWaterfall-\(Self.timestampForFilename()).mov"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.recorder.start(view: sceneView, audioFormat: AudioFormatConverter.canonicalFormat, outputURL: url)
                self.isRecording = true
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recorder.stop { [weak self] savedURL in
            Task { @MainActor in
                if savedURL == nil {
                    self?.errorMessage = "Recording failed to save."
                }
            }
        }
    }

    private static func timestampForFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}
