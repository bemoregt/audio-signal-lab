//
//  SpectrogramView.swift
//  AudioWaterfall
//

import SwiftUI
import AppKit
import Accelerate

/// Classic 2D spectrogram: same SpectrumHistory data as the 3D waterfall, but time runs
/// left→right and frequency runs bottom→top, with amplitude encoded as color (the
/// traditional spectrogram convention) rather than height.
struct SpectrogramView: NSViewRepresentable {
    let history: SpectrumHistory
    var colormap: Colormap = .turboLike
    var backgroundColorOption: BackgroundColorOption = .black

    func makeCoordinator() -> Coordinator {
        Coordinator(history: history, colormap: colormap)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundColorOption.color.cgColor
        // The source image is only timeSteps × binCount pixels, stretched to fill the view —
        // nearest-neighbor keeps each time/frequency cell a crisp block instead of a blur.
        view.layer?.magnificationFilter = .nearest
        context.coordinator.hostView = view

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak coordinator = context.coordinator] _ in
            coordinator?.renderFrameIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        context.coordinator.timer = timer

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.colormap = colormap
        nsView.layer?.backgroundColor = backgroundColorOption.color.cgColor
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
    }

    final class Coordinator {
        var colormap: Colormap {
            didSet {
                guard colormap != cachedLUTColormap else { return }
                cachedLUT = Self.makeLUT(for: colormap)
                cachedLUTColormap = colormap
            }
        }
        weak var hostView: NSView?
        var timer: Timer?

        private let history: SpectrumHistory
        private let binCount: Int
        private var lastRenderedVersion = -1
        private var cachedLUT: [UInt8]
        private var cachedLUTColormap: Colormap?

        init(history: SpectrumHistory, colormap: Colormap) {
            self.history = history
            self.colormap = colormap
            self.binCount = history.binCount
            self.cachedLUT = Self.makeLUT(for: colormap)
            self.cachedLUTColormap = colormap
        }

        func renderFrameIfNeeded() {
            guard history.version != lastRenderedVersion, let hostView else { return }
            lastRenderedVersion = history.version
            guard let image = Self.makeImage(rows: history.snapshot(), binCount: binCount, lut: cachedLUT) else { return }
            hostView.layer?.contents = image
        }

        /// 256-entry amplitude→RGBA table, built once per colormap instead of re-running the
        /// colormap's stop interpolation for every one of the (up to) ~500K pixels per frame —
        /// that per-pixel interpolation was costing ~650ms/frame in a debug build.
        private static func makeLUT(for colormap: Colormap) -> [UInt8] {
            var lut = [UInt8](repeating: 0, count: 256 * 4)
            for i in 0..<256 {
                let (r, g, b, a) = colormap.rgba(for: Float(i) / 255)
                lut[i * 4] = UInt8(max(0, min(255, r * 255)))
                lut[i * 4 + 1] = UInt8(max(0, min(255, g * 255)))
                lut[i * 4 + 2] = UInt8(max(0, min(255, b * 255)))
                lut[i * 4 + 3] = UInt8(max(0, min(255, a * 255)))
            }
            return lut
        }

        private static func makeImage(rows: [[Float]], binCount: Int, lut: [UInt8]) -> CGImage? {
            let timeSteps = rows.count
            guard timeSteps > 0, binCount > 0 else { return nil }

            var pixels = [UInt8](repeating: 0, count: timeSteps * binCount * 4)
            // Reused across columns: vDSP clips/scales/converts a whole column's amplitudes to
            // LUT indices in one vectorized pass instead of a scalar clamp+multiply per pixel
            // — this is what took the per-frame cost from ~650ms to a few ms in a debug build.
            var clipped = [Float](repeating: 0, count: binCount)
            var indices = [UInt8](repeating: 0, count: binCount)
            var lowClip: Float = 0
            var highClip: Float = 1
            var scale: Float = 255

            pixels.withUnsafeMutableBufferPointer { pixelBuffer in
                lut.withUnsafeBufferPointer { lutBuffer in
                    for x in 0..<timeSteps {
                        // rows[0] is newest; put it at the right edge, oldest at the left.
                        let row = rows[timeSteps - 1 - x]
                        vDSP_vclip(row, 1, &lowClip, &highClip, &clipped, 1, vDSP_Length(binCount))
                        vDSP_vsmul(clipped, 1, &scale, &clipped, 1, vDSP_Length(binCount))
                        vDSP_vfixu8(clipped, 1, &indices, 1, vDSP_Length(binCount))

                        indices.withUnsafeBufferPointer { indexBuffer in
                            for imageRow in 0..<binCount {
                                // Image row 0 is the top in CG's coordinate system; put the
                                // highest frequency bin there so low frequencies sit at the
                                // bottom, as usual.
                                let bin = binCount - 1 - imageRow
                                let lutIndex = Int(indexBuffer[bin]) * 4
                                let pixelIndex = (imageRow * timeSteps + x) * 4
                                pixelBuffer[pixelIndex] = lutBuffer[lutIndex]
                                pixelBuffer[pixelIndex + 1] = lutBuffer[lutIndex + 1]
                                pixelBuffer[pixelIndex + 2] = lutBuffer[lutIndex + 2]
                                pixelBuffer[pixelIndex + 3] = lutBuffer[lutIndex + 3]
                            }
                        }
                    }
                }
            }

            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(
                width: timeSteps,
                height: binCount,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: timeSteps * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }
    }
}
