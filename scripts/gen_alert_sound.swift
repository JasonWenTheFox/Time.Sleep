#!/usr/bin/env swift

import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: gen_alert_sound.swift <output.wav>\n", stderr)
    exit(2)
}

let sampleRate: UInt32 = 44_100
let channels: UInt16 = 1
let bitsPerSample: UInt16 = 16
let tones: [(frequency: Double, duration: Double)] = [
    (880, 0.20),
    (0, 0.08),
    (1_108.73, 0.24),
    (0, 0.08),
    (1_318.51, 0.34)
]

var samples: [Int16] = []
for tone in tones {
    let count = Int(Double(sampleRate) * tone.duration)
    for index in 0..<count {
        guard tone.frequency > 0 else {
            samples.append(0)
            continue
        }
        let attack = min(1, Double(index) / (Double(sampleRate) * 0.015))
        let release = min(1, Double(count - index) / (Double(sampleRate) * 0.05))
        let envelope = min(attack, release)
        let phase = 2 * Double.pi * tone.frequency * Double(index) / Double(sampleRate)
        let value = sin(phase) * envelope * 0.55
        samples.append(Int16(value * Double(Int16.max)))
    }
}

var pcm = Data()
for sample in samples {
    var littleEndian = sample.littleEndian
    withUnsafeBytes(of: &littleEndian) { pcm.append(contentsOf: $0) }
}

var wav = Data()
func appendASCII(_ value: String) {
    wav.append(contentsOf: value.utf8)
}
func appendUInt16(_ value: UInt16) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { wav.append(contentsOf: $0) }
}
func appendUInt32(_ value: UInt32) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { wav.append(contentsOf: $0) }
}

let bytesPerSample = UInt16(bitsPerSample / 8)
let byteRate = sampleRate * UInt32(channels * bytesPerSample)
let blockAlign = channels * bytesPerSample

appendASCII("RIFF")
appendUInt32(UInt32(36 + pcm.count))
appendASCII("WAVE")
appendASCII("fmt ")
appendUInt32(16)
appendUInt16(1)
appendUInt16(channels)
appendUInt32(sampleRate)
appendUInt32(byteRate)
appendUInt16(blockAlign)
appendUInt16(bitsPerSample)
appendASCII("data")
appendUInt32(UInt32(pcm.count))
wav.append(pcm)

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
try wav.write(to: outputURL, options: .atomic)
print("alert sound written: \(outputURL.path)")
