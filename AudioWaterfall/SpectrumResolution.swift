//
//  SpectrumResolution.swift
//  AudioWaterfall
//

import Foundation

enum SpectrumResolution: Int, CaseIterable, Identifiable {
    case low = 32
    case medium = 64
    case high = 128
    case veryHigh = 256
    case ultra = 512

    var id: Int { rawValue }
    var binCount: Int { rawValue }

    var label: String {
        switch self {
        case .low: return "Low (32)"
        case .medium: return "Medium (64)"
        case .high: return "High (128)"
        case .veryHigh: return "Very High (256)"
        case .ultra: return "Ultra (512)"
        }
    }
}
