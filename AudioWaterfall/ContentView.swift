//
//  ContentView.swift
//  AudioWaterfall
//

import SwiftUI
import UniformTypeIdentifiers

// M6: mic/file/system-audio source picker, colormap picker, error display — final shell.
struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var showFileImporter = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Source", selection: $viewModel.selectedSource) {
                    ForEach(AudioSourceKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                .disabled(viewModel.isRunning)

                if viewModel.selectedSource == .file {
                    Button("Open File…") { showFileImporter = true }
                        .disabled(viewModel.isRunning)
                    if let url = viewModel.selectedFileURL {
                        Text(url.lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Button(viewModel.isRunning ? "Stop" : "Start") {
                    viewModel.isRunning ? viewModel.stop() : viewModel.start()
                }

                Divider().frame(height: 20)

                Picker("Colormap", selection: $viewModel.colormap) {
                    ForEach(Colormap.allCases) { map in
                        Text(map.rawValue).tag(map)
                    }
                }
                .frame(width: 160)

                Picker("Background", selection: $viewModel.backgroundColorOption) {
                    ForEach(BackgroundColorOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .frame(width: 160)

                Picker("Resolution", selection: $viewModel.resolution) {
                    ForEach(SpectrumResolution.allCases) { res in
                        Text(res.label).tag(res)
                    }
                }
                .frame(width: 160)

                Picker("View", selection: $viewModel.cameraViewpoint) {
                    ForEach(CameraViewpoint.allCases) { viewpoint in
                        Text(viewpoint.rawValue).tag(viewpoint)
                    }
                }
                .frame(width: 180)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            HStack(spacing: 16) {
                Toggle("Log Scale", isOn: $viewModel.logScaleEnabled)
                Spacer()
            }
            .padding(8)

            WaterfallSceneView(history: viewModel.history, colormap: viewModel.colormap, backgroundColorOption: viewModel.backgroundColorOption, cameraViewpoint: viewModel.cameraViewpoint)
                .id(viewModel.resolution)
        }
        .frame(minWidth: 760, minHeight: 500)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                viewModel.selectedFileURL = url
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    ContentView()
}
