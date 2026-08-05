//
//  AudioFormatConverter.swift
//  AudioWaterfall
//

import AVFoundation

final class AudioFormatConverter {
    static let canonicalFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        if format == Self.canonicalFormat {
            return buffer
        }

        if converter == nil || sourceFormat != format {
            converter = AVAudioConverter(from: format, to: Self.canonicalFormat)
            sourceFormat = format
        }
        guard let converter else { return nil }

        let ratio = Self.canonicalFormat.sampleRate / format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: Self.canonicalFormat, frameCapacity: outputCapacity) else {
            return nil
        }

        var suppliedInput = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error else { return nil }
        return outputBuffer
    }
}
