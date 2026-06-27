import Foundation
import SwiftUI

// MARK: - LED

struct LEDColor: Identifiable {
    let id = UUID()
    var color: Color = .red
    var count: Int = 1     // 0-15 flashes per color
    var onMs: Int  = 150   // on duration, quantised to 100 ms steps (0-1500 ms)
    var gapMs: Int = 80    // gap duration, quantised to 100 ms steps (0-25500 ms)

    var rgb332: UInt8 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        let r3 = UInt8(r * 7) & 0x07
        let g3 = UInt8(g * 7) & 0x07
        let b2 = UInt8(b * 3) & 0x03
        return (r3 << 5) | (g3 << 2) | b2
    }

    var onNibble: UInt8  { UInt8(min(onMs  / 100, 15)) }
    var gapByte:  UInt8  { UInt8(min(gapMs / 100, 255)) }
}

struct LEDPattern {
    var brightness: Int = 8        // 1-16
    var colors: [LEDColor] = [
        LEDColor(color: .red,   count: 3, onMs: 150, gapMs: 80),
        LEDColor(color: .clear, count: 0, onMs: 0,   gapMs: 0),
        LEDColor(color: .clear, count: 0, onMs: 0,   gapMs: 0),
    ]
    var repeats: Int = 1           // 1-254

    static let presets: [(name: String, pattern: LEDPattern)] = [
        ("Single Flash",  LEDPattern(brightness: 8,
                                     colors: [LEDColor(color: .white, count: 1, onMs: 150, gapMs: 0),
                                              LEDColor(), LEDColor()],
                                     repeats: 1)),
        ("Double Flash",  LEDPattern(brightness: 8,
                                     colors: [LEDColor(color: .white, count: 2, onMs: 80, gapMs: 60),
                                              LEDColor(), LEDColor()],
                                     repeats: 1)),
        ("Alarm",         LEDPattern(brightness: 16,
                                     colors: [LEDColor(color: .red,    count: 1, onMs: 100, gapMs: 0),
                                              LEDColor(color: .orange, count: 1, onMs: 100, gapMs: 0),
                                              LEDColor(color: .red,    count: 1, onMs: 100, gapMs: 0)],
                                     repeats: 3)),
    ]
}

// MARK: - Buzzer

struct BuzzerStep: Identifiable {
    let id = UUID()
    var hz: Int  = 2000   // 0 = silence/gap, 200-4000 Hz for tone
    var ms: Int  = 120    // duration in ms

    static let fmin = 200
    static let fmax = 4000

    var freqIndex: UInt8 {
        guard hz > 0 else { return 0 }
        if hz >= Self.fmax { return 255 }
        if hz <= Self.fmin { return 1 }
        return UInt8(1 + (hz - Self.fmin) * 254 / (Self.fmax - Self.fmin))
    }

    var durationUnits: UInt8 { UInt8(min(ms / 5, 255)) }
}

struct BuzzerPattern {
    var instance: UInt8 = 0
    var repeats: Int = 1
    var steps: [BuzzerStep] = [BuzzerStep(hz: 2000, ms: 120)]

    enum Preset: String, CaseIterable {
        case single = "Single"
        case double = "Double"
        case alarm  = "Alarm"

        var pattern: BuzzerPattern {
            switch self {
            case .single:
                return BuzzerPattern(repeats: 1, steps: [BuzzerStep(hz: 2000, ms: 150)])
            case .double:
                return BuzzerPattern(repeats: 1, steps: [BuzzerStep(hz: 2000, ms: 80),
                                                          BuzzerStep(hz: 0,    ms: 60),
                                                          BuzzerStep(hz: 2000, ms: 80)])
            case .alarm:
                return BuzzerPattern(repeats: 2, steps: [BuzzerStep(hz: 3000, ms: 100),
                                                          BuzzerStep(hz: 1500, ms: 100),
                                                          BuzzerStep(hz: 3000, ms: 100)])
            }
        }
    }
}

// MARK: - NFC

enum NFCPayloadType: UInt8, CaseIterable, Identifiable {
    case text      = 0x00
    case uri       = 0x01
    case wellKnown = 0x02
    case mime      = 0x03
    case rawNDEF   = 0x04

    var id: UInt8 { rawValue }
    var displayName: String {
        switch self {
        case .text:      return "Text"
        case .uri:       return "URI"
        case .wellKnown: return "Well-known"
        case .mime:      return "MIME"
        case .rawNDEF:   return "Raw NDEF (hex)"
        }
    }
}
