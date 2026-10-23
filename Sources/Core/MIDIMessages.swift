import Foundation

/// Сообщения MIDI, которые нужны плееру
enum MIDIEvent: Equatable {
    /// F1 xx — один из восьми кусочков MTC
    case quarterFrame(UInt8)
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    /// SysEx без F0/F7 (MTC full frame, MMC)
    case sysex([UInt8])
}

/// Разбор UMP (MIDI 1.0 внутри Universal MIDI Packet) — в таком виде CoreMIDI отдаёт данные в новом API.
/// Один парсер на поток событий: SysEx может прийти несколькими пакетами.
struct UMPParser {
    private var sysexBuffer: [UInt8] = []
    private var inSysex = false

    static func wordCount(forType type: UInt32) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }

    mutating func parse(_ words: [UInt32]) -> [MIDIEvent] {
        var events: [MIDIEvent] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            let type = w >> 28
            let n = Self.wordCount(forType: type)
            guard i + n <= words.count else { break }
            switch type {
            case 0x1: // системные сообщения
                if (w >> 16) & 0xFF == 0xF1 {
                    events.append(.quarterFrame(UInt8((w >> 8) & 0x7F)))
                }
            case 0x2: // канальные сообщения MIDI 1.0
                let status = UInt8((w >> 16) & 0xFF)
                let d1 = UInt8((w >> 8) & 0x7F)
                let d2 = UInt8(w & 0x7F)
                if status & 0xF0 == 0x90 && d2 > 0 {
                    events.append(.noteOn(channel: status & 0x0F, note: d1, velocity: d2))
                }
            case 0x3: // SysEx7, до 6 байт в пакете
                let w1 = words[i + 1]
                let status = (w >> 20) & 0xF
                let count = min(Int((w >> 16) & 0xF), 6)
                let all: [UInt8] = [UInt8((w >> 8) & 0xFF), UInt8(w & 0xFF),
                                    UInt8(w1 >> 24), UInt8((w1 >> 16) & 0xFF),
                                    UInt8((w1 >> 8) & 0xFF), UInt8(w1 & 0xFF)]
                let bytes = Array(all.prefix(count))
                switch status {
                case 0:
                    events.append(.sysex(bytes))
                    inSysex = false
                    sysexBuffer = []
                case 1:
                    sysexBuffer = bytes
                    inSysex = true
                case 2:
                    if inSysex { sysexBuffer += bytes }
                case 3:
                    if inSysex { events.append(.sysex(sysexBuffer + bytes)) }
                    inSysex = false
                    sysexBuffer = []
                default:
                    break
                }
            default:
                break
            }
            i += n
        }
        return events
    }
}

/// Сборка UMP — для эмулятора и тестов
enum UMPEncoder {
    static func quarterFrame(_ value: UInt8) -> [UInt32] {
        [0x10F1_0000 | UInt32(value & 0x7F) << 8]
    }

    static func noteOn(channel: UInt8, note: UInt8, velocity: UInt8) -> [UInt32] {
        [0x2090_0000 | UInt32(channel & 0x0F) << 16 | UInt32(note & 0x7F) << 8 | UInt32(velocity & 0x7F)]
    }

    static func noteOff(channel: UInt8, note: UInt8) -> [UInt32] {
        [0x2080_0000 | UInt32(channel & 0x0F) << 16 | UInt32(note & 0x7F) << 8]
    }

    /// payload — без F0/F7
    static func sysex(_ payload: [UInt8]) -> [UInt32] {
        var chunks: [[UInt8]] = stride(from: 0, to: payload.count, by: 6).map {
            Array(payload[$0..<min($0 + 6, payload.count)])
        }
        if chunks.isEmpty { chunks = [[]] }
        var words: [UInt32] = []
        for (index, chunk) in chunks.enumerated() {
            let status: UInt32
            if chunks.count == 1 { status = 0 }
            else if index == 0 { status = 1 }
            else if index == chunks.count - 1 { status = 3 }
            else { status = 2 }
            let b = chunk.map(UInt32.init) + Array(repeating: 0, count: 6 - chunk.count)
            words.append(0x3000_0000 | status << 20 | UInt32(chunk.count) << 16 | b[0] << 8 | b[1])
            words.append(b[2] << 24 | b[3] << 16 | b[4] << 8 | b[5])
        }
        return words
    }
}
