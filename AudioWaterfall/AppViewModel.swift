//
//  AppViewModel.swift
//  AudioWaterfall
//

import Combine
import Foundation

enum AudioSourceKind: String, CaseIterable, Identifiable {
    case microphone = "Microphone"
    case file = "File"
    case systemAudio = "System Audio"

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
    @Published var resolution: SpectrumResolution = .high {
        didSet { applyResolution() }
    }
    @Published var lowFrequencyFilteringEnabled = true {
        didSet { analyzer.smoothingEnabled = lowFrequencyFilteringEnabled }
    }
    @Published var logScaleEnabled = true {
        didSet { analyzer.logScaleEnabled = logScaleEnabled }
    }

    @Published private(set) var history: SpectrumHistory

    private let micSource = MicrophoneAudioSource()
    private let fileSource = FileAudioSource()
    private let systemAudioSource = SystemAudioSource()
    private let analyzer = SpectrumAnalyzer()
    private var pushTimer: Timer?
    private var activeSource: AudioSource?

    init() {
        // Can't read `self.resolution` before `history` is assigned, so use the same
        // static default directly instead.
        history = SpectrumHistory(timeSteps: 32, binCount: SpectrumResolution.high.binCount)
        analyzer.visualBinCount = SpectrumResolution.high.binCount
    }

    /// Resolution changes swap in a fresh SpectrumHistory (its row size is fixed at
    /// construction) — the waterfall briefly starts blank at the new resolution rather
    /// than trying to resample old rows into the new bin count.
    private func applyResolution() {
        analyzer.visualBinCount = resolution.binCount
        history = SpectrumHistory(timeSteps: history.timeSteps, binCount: resolution.binCount)
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
                }
                isRunning = true
                pushTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    // Timer's closure type isn't statically MainActor-isolated, but this
                    // timer is always scheduled from (and fires on) the main run loop.
                    MainActor.assumeIsolated {
                        guard let self, let spectrum = self.analyzer.consumeLatest() else { return }
                        self.history.push(spectrum)
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
        activeSource?.stop()
        activeSource = nil
        pushTimer?.invalidate()
        pushTimer = nil
        isRunning = false
    }
}
