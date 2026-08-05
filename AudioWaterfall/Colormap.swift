//
//  Colormap.swift
//  AudioWaterfall
//

import Foundation

enum Colormap: String, CaseIterable, Identifiable {
    case turboLike = "Turbo"
    case grayscale = "Grayscale"
    case purple = "Purple"
    case fire = "Fire"
    case viridis = "Viridis"

    var id: String { rawValue }

    func rgba(for amplitude: Float) -> (r: Float, g: Float, b: Float, a: Float) {
        let t = min(max(amplitude, 0), 1)
        switch self {
        case .grayscale:
            return (t, t, t, 1)
        case .turboLike:
            return Colormap.turboStops.interpolated(at: t)
        case .purple:
            return Colormap.purpleStops.interpolated(at: t)
        case .fire:
            return Colormap.fireStops.interpolated(at: t)
        case .viridis:
            return Colormap.viridisStops.interpolated(at: t)
        }
    }

    private static let turboStops: [(position: Float, color: (Float, Float, Float))] = [
        (0.0, (0.0, 0.0, 0.35)),
        (0.25, (0.0, 0.6, 0.9)),
        (0.5, (0.0, 0.85, 0.2)),
        (0.75, (1.0, 0.9, 0.0)),
        (1.0, (0.9, 0.1, 0.05)),
    ]

    // Plasma-style: multi-hue gradient anchored in purple, not a single-hue ramp.
    private static let purpleStops: [(position: Float, color: (Float, Float, Float))] = [
        (0.0, (0.05, 0.03, 0.35)),
        (0.25, (0.42, 0.00, 0.66)),
        (0.5, (0.80, 0.20, 0.55)),
        (0.75, (0.97, 0.55, 0.20)),
        (1.0, (0.94, 0.98, 0.13)),
    ]

    // Inferno-style: multi-hue gradient anchored in red, not a single-hue ramp.
    private static let fireStops: [(position: Float, color: (Float, Float, Float))] = [
        (0.0, (0.02, 0.02, 0.10)),
        (0.25, (0.42, 0.01, 0.35)),
        (0.5, (0.80, 0.25, 0.10)),
        (0.75, (0.98, 0.65, 0.10)),
        (1.0, (0.99, 0.97, 0.75)),
    ]

    private static let viridisStops: [(position: Float, color: (Float, Float, Float))] = [
        (0.0, (0.27, 0.0, 0.33)),
        (0.25, (0.20, 0.35, 0.55)),
        (0.5, (0.13, 0.57, 0.55)),
        (0.75, (0.47, 0.75, 0.32)),
        (1.0, (0.99, 0.90, 0.14)),
    ]
}

private extension Array where Element == (position: Float, color: (Float, Float, Float)) {
    func interpolated(at t: Float) -> (Float, Float, Float, Float) {
        for i in 1..<count {
            let lower = self[i - 1]
            let upper = self[i]
            if t <= upper.position {
                let span = upper.position - lower.position
                let localT = span > 0 ? (t - lower.position) / span : 0
                let r = lower.color.0 + (upper.color.0 - lower.color.0) * localT
                let g = lower.color.1 + (upper.color.1 - lower.color.1) * localT
                let b = lower.color.2 + (upper.color.2 - lower.color.2) * localT
                return (r, g, b, 1)
            }
        }
        let last = self.last!.color
        return (last.0, last.1, last.2, 1)
    }
}
