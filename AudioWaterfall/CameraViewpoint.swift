//
//  CameraViewpoint.swift
//  AudioWaterfall
//

import Foundation

/// A preset 3D camera angle/zoom for viewing the waterfall, expressed the same way
/// WaterfallSceneView's orbit camera is driven internally: yaw/pitch in degrees around the
/// fixed look-at target, and distance in scene units (see its min/maxCameraDistance for the
/// valid zoom range).
enum CameraViewpoint: String, CaseIterable, Identifiable {
    case standard = "Default"
    case cinematic = "Cinematic"
    case closeUp = "Close-Up"
    case topDown = "Top-Down"
    case sideProfile = "Side Profile"
    case lowAngle = "Low Angle"
    case wideOverview = "Wide Overview"

    var id: String { rawValue }

    var yawDegrees: Float {
        switch self {
        case .standard: return 0
        case .cinematic: return 40
        case .closeUp: return 0
        case .topDown: return 0
        case .sideProfile: return 90
        case .lowAngle: return 15
        case .wideOverview: return -35
        }
    }

    var pitchDegrees: Float {
        switch self {
        case .standard: return 20
        case .cinematic: return 22
        case .closeUp: return 8
        case .topDown: return 75
        case .sideProfile: return 12
        case .lowAngle: return 4
        case .wideOverview: return 30
        }
    }

    var distance: Float {
        switch self {
        case .standard: return 23.4
        case .cinematic: return 26
        case .closeUp: return 11
        case .topDown: return 28
        case .sideProfile: return 22
        case .lowAngle: return 15
        case .wideOverview: return 48
        }
    }
}
