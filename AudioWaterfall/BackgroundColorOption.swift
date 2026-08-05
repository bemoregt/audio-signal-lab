//
//  BackgroundColorOption.swift
//  AudioWaterfall
//

import AppKit

enum BackgroundColorOption: String, CaseIterable, Identifiable {
    case black = "Black"
    case darkPurple = "Dark Purple"
    case white = "White"
    case darkGreen = "Dark Green"
    case darkRed = "Dark Red"

    var id: String { rawValue }

    var color: NSColor {
        switch self {
        case .black:
            return NSColor.black
        case .darkPurple:
            return NSColor(calibratedRed: 0.16, green: 0.02, blue: 0.24, alpha: 1)
        case .white:
            return NSColor.white
        case .darkGreen:
            return NSColor(calibratedRed: 0.02, green: 0.18, blue: 0.05, alpha: 1)
        case .darkRed:
            return NSColor(calibratedRed: 0.22, green: 0.02, blue: 0.03, alpha: 1)
        }
    }
}
