import Foundation

/// Частота кадров MTC (код из старшего кусочка часов)
enum MTCRate: Int {
    case fps24 = 0, fps25 = 1, fps2997drop = 2, fps30 = 3

    var fps: Double {
        switch self {
        case .fps24: return 24
        case .fps25: return 25
        case .fps2997drop: return 30000.0 / 1001.0
        case .fps30: return 30
        }
    }

    /// Номинальное число кадров в секунде таймкода
    var nominalFrames: Int {
        switch self {
        case .fps24: return 24
        case .fps25: return 25
        case .fps2997drop, .fps30: return 30
        }
    }

    var label: String {
        switch self {
        case .fps24: return "24"
        case .fps25: return "25"
        case .fps2997drop: return "29.97 drop"
        case .fps30: return "30"
        }
    }
}

struct Timecode: Equatable {
    var hours = 0, minutes = 0, seconds = 0, frames = 0
    var rate: MTCRate = .fps25

    /// Реальное время в секундах от 00:00:00:00
    var realSeconds: Double {
        if rate == .fps2997drop {
            // drop-frame: в каждой минуте, кроме кратных 10, пропущены кадры 0 и 1
            let totalMinutes = 60 * hours + minutes
            let frameNumber = 108_000 * hours + 1800 * minutes + 30 * seconds + frames
                - 2 * (totalMinutes - totalMinutes / 10)
            return Double(frameNumber) / rate.fps
        }
        return Double(hours * 3600 + minutes * 60 + seconds) + Double(frames) / Double(rate.nominalFrames)
    }

    /// Таймкод из секунд (для эмулятора и подписей; drop-frame считается как 30 — для подписи достаточно)
    init(hours: Int = 0, minutes: Int = 0, seconds: Int = 0, frames: Int = 0, rate: MTCRate = .fps25) {
        self.hours = hours; self.minutes = minutes; self.seconds = seconds; self.frames = frames; self.rate = rate
    }

    init(realSeconds value: Double, rate: MTCRate) {
        let fpsInt = rate.nominalFrames
        // +1 мс: позиция из часов может быть на доли миллисекунды раньше кадра
        let totalFrames = Int((max(0, value) * Double(fpsInt) + 0.025).rounded(.down))
        frames = totalFrames % fpsInt
        let totalSeconds = totalFrames / fpsInt
        seconds = totalSeconds % 60
        minutes = (totalSeconds / 60) % 60
        hours = (totalSeconds / 3600) % 24
        self.rate = rate
    }

    var text: String {
        String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }

    /// Разбор «01:02:03:04», «01:02:03» или «1:02:03.5» (секунды с дробью)
    static func parse(_ s: String, rate: MTCRate = .fps25) -> Double? {
        let parts = s.split(separator: ":").map(String.init)
        guard (2...4).contains(parts.count) else { return nil }
        if parts.count == 4, let h = Int(parts[0]), let m = Int(parts[1]), let sec = Int(parts[2]), let f = Int(parts[3]) {
            return Timecode(hours: h, minutes: m, seconds: sec, frames: f, rate: rate).realSeconds
        }
        let nums = parts.compactMap(Double.init)
        guard nums.count == parts.count else { return nil }
        return nums.reduce(0) { $0 * 60 + $1 }
    }
}

/// Сборка таймкода из восьми кусочков quarter frame
struct MTCDecoder {
    private var pieces = [UInt8](repeating: 0, count: 8)
    private var mask: UInt8 = 0
    private var lastIndex = -1

    mutating func reset() {
        mask = 0
        lastIndex = -1
    }

    /// На восьмом кусочке возвращает позицию (секунды) на момент прихода этого кусочка.
    /// Кусочек 0 отправляется в начале кадра F, кусочек 7 — через 1¾ кадра, поэтому добавляем 1.75 кадра.
    mutating func feed(_ byte: UInt8) -> (position: Double, rate: MTCRate)? {
        let index = Int(byte >> 4) & 0x7
        // Тот же кусочек пришёл дважды (двойное подключение, повтор в сети) — пропускаем, сборку не ломаем
        if index == lastIndex, pieces[index] == byte & 0x0F, mask & (1 << UInt8(index)) != 0 { return nil }
        if index != lastIndex + 1 { mask = 0 }
        lastIndex = index
        pieces[index] = byte & 0x0F
        mask |= 1 << UInt8(index)
        guard index == 7, mask == 0xFF else { return nil }
        let rate = MTCRate(rawValue: Int(pieces[7] >> 1) & 0x3) ?? .fps25
        let tc = Timecode(hours: Int(pieces[6]) | Int(pieces[7] & 0x1) << 4,
                          minutes: Int(pieces[4]) | Int(pieces[5] & 0x3) << 4,
                          seconds: Int(pieces[2]) | Int(pieces[3] & 0x3) << 4,
                          frames: Int(pieces[0]) | Int(pieces[1] & 0x1) << 4,
                          rate: rate)
        return (tc.realSeconds + 1.75 / rate.fps, rate)
    }
}

enum MTCEncoder {
    /// Восемь кусочков quarter frame для кадра tc
    static func quarterFrames(_ tc: Timecode) -> [UInt8] {
        let values: [Int] = [
            tc.frames & 0x0F, (tc.frames >> 4) & 0x1,
            tc.seconds & 0x0F, (tc.seconds >> 4) & 0x3,
            tc.minutes & 0x0F, (tc.minutes >> 4) & 0x3,
            tc.hours & 0x0F, ((tc.hours >> 4) & 0x1) | (tc.rate.rawValue << 1),
        ]
        return values.enumerated().map { UInt8($0.offset << 4 | $0.element) }
    }

    /// MTC full frame (без F0/F7)
    static func fullFrame(_ tc: Timecode) -> [UInt8] {
        [0x7F, 0x7F, 0x01, 0x01, UInt8(tc.rate.rawValue << 5 | tc.hours), UInt8(tc.minutes), UInt8(tc.seconds), UInt8(tc.frames)]
    }

    static func mmc(_ command: UInt8) -> [UInt8] {
        [0x7F, 0x7F, 0x06, command]
    }

    /// MMC Locate (как шлёт Logic)
    static func mmcLocate(_ tc: Timecode) -> [UInt8] {
        [0x7F, 0x7F, 0x06, 0x44, 0x06, 0x01, UInt8(tc.rate.rawValue << 5 | tc.hours), UInt8(tc.minutes), UInt8(tc.seconds), UInt8(tc.frames), 0x00]
    }
}

enum MTCSysex: Equatable {
    case fullFrame(position: Double, rate: MTCRate)
    case mmcStop
    case mmcPlay
    case mmcPause
    /// MMC Locate — Logic шлёт его при старте и при остановке (вместо MMC Stop)
    case mmcLocate(position: Double)
    case other

    static func parse(_ p: [UInt8]) -> MTCSysex {
        guard p.count >= 4, p[0] == 0x7F else { return .other }
        if p[2] == 0x01, p[3] == 0x01, p.count >= 8 {
            let rate = MTCRate(rawValue: Int(p[4] >> 5) & 0x3) ?? .fps25
            let tc = Timecode(hours: Int(p[4] & 0x1F), minutes: Int(p[5]), seconds: Int(p[6]), frames: Int(p[7]), rate: rate)
            return .fullFrame(position: tc.realSeconds, rate: rate)
        }
        // Locate: 7F dev 06 44 06 01 hr mn sc fr subframe
        if p[2] == 0x06, p[3] == 0x44, p.count >= 10, p[5] == 0x01 {
            let rate = MTCRate(rawValue: Int(p[6] >> 5) & 0x3) ?? .fps25
            let tc = Timecode(hours: Int(p[6] & 0x1F), minutes: Int(p[7]), seconds: Int(p[8]), frames: Int(p[9] & 0x1F), rate: rate)
            return .mmcLocate(position: tc.realSeconds)
        }
        if p[2] == 0x06 {
            switch p[3] {
            case 0x01: return .mmcStop
            case 0x02, 0x03: return .mmcPlay
            case 0x09: return .mmcPause
            default: return .other
            }
        }
        return .other
    }
}

/// Часы Logic по MTC. Полный код приходит каждые 2 кадра, между ними позицию продолжаем по своим часам.
/// Сеть добавляет задержку — берём максимум смещения за последние 2 с: это самый «быстрый», наименее задержанный пакет.
struct MTCClock {
    static let timeout = 0.3
    static let window = 2.0

    private var samples: [(host: Double, offset: Double)] = []
    private(set) var lastQuarterFrameHost: Double?
    private(set) var rate: MTCRate = .fps25

    mutating func reset() {
        samples = []
    }

    /// Остановка (MMC Stop) — считаем, что таймкода больше нет
    mutating func stop() {
        samples = []
        lastQuarterFrameHost = nil
    }

    mutating func noteQuarterFrame(host: Double) {
        lastQuarterFrameHost = max(host, lastQuarterFrameHost ?? host)
    }

    /// Идут ли кусочки MTC прямо сейчас
    func isReceiving(at now: Double) -> Bool {
        guard let last = lastQuarterFrameHost else { return false }
        return now - last < Self.timeout
    }

    mutating func addAnchor(position: Double, host: Double, rate: MTCRate) {
        self.rate = rate
        let offset = position - host
        // Перемотка — старые замеры больше не годятся
        if let estimate = offsetEstimate, abs(offset - estimate) > 0.5 {
            samples.removeAll()
        }
        samples.append((host, offset))
        samples.removeAll { host - $0.host > Self.window }
    }

    var hasAnchor: Bool { !samples.isEmpty }

    private var offsetEstimate: Double? {
        samples.map(\.offset).max()
    }

    /// Позиция Logic (секунды MTC) в момент now; nil — таймкода нет
    func position(at now: Double) -> Double? {
        guard isReceiving(at: now), let offset = offsetEstimate else { return nil }
        return now + offset
    }

    /// Позиция в момент host без проверки свежести (для меток, пришедших до первого полного кода)
    func extrapolatedPosition(at host: Double) -> Double? {
        offsetEstimate.map { host + $0 }
    }
}
