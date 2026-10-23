import Foundation

// Простые тесты ядра без XCTest: ./test.sh

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("✗ \(message)  (\(URL(fileURLWithPath: file).lastPathComponent):\(line))")
    }
}

func approx(_ a: Double?, _ b: Double, _ eps: Double = 0.005) -> Bool {
    guard let a else { return false }
    return abs(a - b) < eps
}

/// Эмуляция Logic: шлёт MTC с 25 к/с в директор, время — виртуальное
final class FakeLogic {
    let director: Director
    var now: Double = 1000
    var position: Double = 3600   // 01:00:00:00
    var playing = false
    private var qfIndex = 0
    private var groupFrame = 0
    let fps = 25.0

    init(_ director: Director) { self.director = director }

    func play() {
        playing = true
        qfIndex = 0
        // Logic начинает с ровного кадра
        groupFrame = Int((position * fps).rounded(.down))
        position = Double(groupFrame) / fps
    }

    func stop(mmc: Bool = true) {
        playing = false
        if mmc { director.handle(.sysex(MTCEncoder.mmc(0x01)), host: now) }
    }

    func note(_ n: Int) {
        director.handle(.noteOn(channel: 0, note: UInt8(n), velocity: 100), host: now)
    }

    /// Прогнать время вперёд; send=false — связь пропала (Logic играет, но ничего не доходит)
    func advance(_ seconds: Double, send: Bool = true, step: Double = 0.01, onTick: (() -> Void)? = nil) {
        let qfPeriod = 1 / (fps * 4)
        var t = 0.0
        while t < seconds - 1e-9 {
            let dt = min(qfPeriod, seconds - t)
            now += dt
            t += dt
            if playing {
                position += dt
                if send, abs(dt - qfPeriod) < 1e-9 {
                    let k = qfIndex % 8
                    if k == 0 { groupFrame = Int((position * fps - 0.5).rounded()) }
                    let tc = Timecode(realSeconds: Double(groupFrame) / fps + 1e-6, rate: .fps25)
                    director.handle(.quarterFrame(MTCEncoder.quarterFrames(tc)[k]), host: now)
                    qfIndex += 1
                } else if !send {
                    qfIndex = 0
                }
            }
            onTick?()
        }
    }
}

func makeDirector() -> Director {
    let d = Director()
    d.fadeOut = 0.5
    d.markerBaseNote = 36
    d.cues = [1: CueInfo(id: 1, duration: 20), 2: CueInfo(id: 2, duration: 30), 3: CueInfo(id: 3, duration: 10)]
    return d
}

// MARK: - UMP

do {
    var parser = UMPParser()
    let payload: [UInt8] = [0x7F, 0x7F, 0x01, 0x01, 0x21, 0x02, 0x03, 0x04]
    var words = UMPEncoder.quarterFrame(0x35) + UMPEncoder.noteOn(channel: 2, note: 36, velocity: 90)
    words += UMPEncoder.noteOn(channel: 0, note: 40, velocity: 0)   // note on с нулевой скоростью = note off
    words += UMPEncoder.sysex(payload) + UMPEncoder.sysex([0x7F, 0x7F, 0x06, 0x01])
    let events = parser.parse(words)
    check(events == [.quarterFrame(0x35), .noteOn(channel: 2, note: 36, velocity: 90),
                     .sysex(payload), .sysex([0x7F, 0x7F, 0x06, 0x01])], "UMP: разбор смеси сообщений: \(events)")

    // SysEx, разрезанный на разные пакеты
    let split = UMPEncoder.sysex(payload)
    var p2 = UMPParser()
    let first = p2.parse(Array(split[0..<2]))
    let second = p2.parse(Array(split[2...]))
    check(first.isEmpty && second == [.sysex(payload)], "UMP: SysEx из двух пакетов")
}

// MARK: - MTC

do {
    let tc = Timecode(hours: 1, minutes: 23, seconds: 45, frames: 12, rate: .fps25)
    var decoder = MTCDecoder()
    var result: (position: Double, rate: MTCRate)?
    for byte in MTCEncoder.quarterFrames(tc) { result = decoder.feed(byte) }
    check(result?.rate == .fps25, "MTC: частота 25")
    check(approx(result?.position, tc.realSeconds + 1.75 / 25), "MTC: позиция из quarter frame")

    // Сборка начинается только с кусочка 0
    var d2 = MTCDecoder()
    let pieces = MTCEncoder.quarterFrames(tc)
    var got: Any?
    for byte in pieces[3...] { got = d2.feed(byte) }
    check(got == nil, "MTC: неполная группа не даёт позицию")

    check(MTCSysex.parse(MTCEncoder.fullFrame(tc)) == .fullFrame(position: tc.realSeconds, rate: .fps25), "MTC: full frame")
    check(MTCSysex.parse(MTCEncoder.mmc(0x01)) == .mmcStop, "MMC: стоп")

    let df = Timecode(hours: 0, minutes: 10, seconds: 0, frames: 0, rate: .fps2997drop)
    check(approx(df.realSeconds, 600.0, 0.05), "MTC: drop-frame 10 минут ≈ 600 с: \(df.realSeconds)")
    check(Timecode(realSeconds: 3.0, rate: .fps25).text == "00:00:03:00", "Timecode: округление")
    check(approx(Timecode.parse("01:00:10:05"), 3610.2), "Timecode: разбор")
    check(approx(Timecode.parse("1:02.5"), 62.5), "Timecode: разбор мм:сс.д")
}

// MARK: - Часы

do {
    var clock = MTCClock()
    clock.noteQuarterFrame(host: 10)
    clock.addAnchor(position: 100, host: 10, rate: .fps25)
    clock.noteQuarterFrame(host: 10.08)
    clock.addAnchor(position: 100.08, host: 10.1, rate: .fps25)    // пришёл с задержкой 20 мс
    check(approx(clock.position(at: 10.2), 100.2), "Часы: берётся наименее задержанный замер")
    check(clock.position(at: 10.5) == nil, "Часы: таймкод пропал через 0.3 с")
    clock.noteQuarterFrame(host: 10.6)
    clock.addAnchor(position: 50, host: 10.6, rate: .fps25)        // перемотка
    check(approx(clock.position(at: 10.6), 50), "Часы: перемотка сбрасывает замеры")
}

// MARK: - Сценарии шоу

// 1. Метка выучивается, видео держится за таймкод
do {
    let d = makeDirector()
    let logic = FakeLogic(d)
    var learned: [Int: Double] = [:]
    d.onCueLearned = { learned[$0] = $1 }
    check(d.output(at: logic.now) == .logo, "Шоу: до старта — логотип")
    logic.play()
    logic.advance(2)
    check(d.output(at: logic.now) == .logo, "Шоу: вступление без песни — логотип")
    logic.note(36)
    check(approx(learned[1], 3602, 0.02), "Шоу: метка песни 1 выучена: \(String(describing: learned[1]))")
    logic.advance(5)
    if case .song(1, let pos, true) = d.output(at: logic.now) {
        check(approx(pos, 5, 0.02), "Шоу: позиция видео 5 с: \(pos)")
    } else { check(false, "Шоу: должна идти песня 1 по таймкоду") }
    check(d.nextCue(after: d.output(at: logic.now)) == 2, "Шоу: наготове песня 2")

    // Конец видео раньше песни — логотип
    logic.advance(15)
    check(d.output(at: logic.now) == .logo, "Шоу: видео закончилось — логотип")

    // Стоп (автостоп) с MMC — логотип сразу
    logic.position = 3602 + 3
    logic.play()
    logic.advance(1)
    check(d.output(at: logic.now).isSong(1), "Шоу: перемотка внутрь песни 1 по выученной метке")
    logic.stop()
    check(d.output(at: logic.now) == .logo, "Шоу: MMC Stop — сразу логотип")
}

// 2. Связь пропала посреди песни — доигрывает до конца, потом логотип
do {
    let d = makeDirector()
    d.cues[2]!.start = 3700
    let logic = FakeLogic(d)
    logic.position = 3705
    logic.play()
    logic.advance(1)
    check(d.output(at: logic.now).isSong(2, locked: true), "Обрыв: песня 2 по таймкоду")
    var outputs: [ShowOutput] = []
    logic.advance(3, send: false) { outputs.append(d.output(at: logic.now)) }
    let last = d.output(at: logic.now)
    if case .song(2, let pos, false) = last {
        check(approx(pos, 9, 0.05), "Обрыв: позиция продолжается без скачка: \(pos)")
    } else { check(false, "Обрыв: песня должна доигрывать сама: \(last)") }
    check(!outputs.contains(.logo), "Обрыв: ни одного кадра логотипа во время обрыва")
    logic.advance(25, send: false)
    check(d.output(at: logic.now) == .logo, "Обрыв: после конца видео — логотип")

    // Связь вернулась — снова по таймкоду
    logic.advance(0.5)
    check(d.output(at: logic.now) == .logo, "Обрыв: связь вернулась после песни — логотип")
}

// 3. Стоп без MMC (если Logic не шлёт) — песня доигрывает, потом логотип
do {
    let d = makeDirector()
    d.cues[3]!.start = 3800
    let logic = FakeLogic(d)
    logic.position = 3800
    logic.play()
    logic.advance(2)
    logic.stop(mmc: false)
    logic.advance(1)
    check(d.output(at: logic.now).isSong(3, locked: false), "Стоп без MMC: доигрывает")
    logic.advance(10)
    check(d.output(at: logic.now) == .logo, "Стоп без MMC: потом логотип")
}

// 3б. Стоп как в Logic: MMC Locate вместо MMC Stop — сразу логотип
do {
    let d = makeDirector()
    d.cues[3]!.start = 3800
    let logic = FakeLogic(d)
    logic.position = 3800
    d.handle(.sysex(MTCEncoder.mmcLocate(Timecode(realSeconds: 3800, rate: .fps25))), host: logic.now)
    logic.play()
    logic.advance(2)
    check(d.output(at: logic.now).isSong(3, locked: true), "Locate при старте не мешает")
    logic.stop(mmc: false)
    d.handle(.sysex(MTCEncoder.mmcLocate(Timecode(realSeconds: 3802, rate: .fps25))), host: logic.now)
    logic.advance(0.4)
    check(d.output(at: logic.now) == .logo, "Стоп с Locate: логотип: \(d.output(at: logic.now))")
    // Снова Play — песня по таймкоду
    logic.play()
    logic.advance(1)
    check(d.output(at: logic.now).isSong(3, locked: true), "После стопа с Locate снова Play")
    check(MTCSysex.parse([0x7F, 0x7F, 0x06, 0x44, 0x06, 0x01, 0x20, 0x0C, 0x23, 0x06, 0x00]) == .mmcLocate(position: Timecode(hours: 0, minutes: 12, seconds: 35, frames: 6).realSeconds),
          "MMC Locate из лога Logic")
}

// 4. Старт ровно с метки: нота приходит раньше полного кода
do {
    let d = makeDirector()
    let logic = FakeLogic(d)
    logic.position = 3650
    logic.play()
    logic.advance(0.01)
    logic.note(37)
    logic.advance(0.5)
    check(approx(d.cues[2]?.start, 3650, 0.03), "Метка до полного кода: \(String(describing: d.cues[2]?.start))")
    check(d.output(at: logic.now).isSong(2, locked: true), "Метка до полного кода: песня 2 идёт")
}

// 4б. Chase: Play с середины длинной ноты-метки не перезаписывает метку
do {
    let d = makeDirector()
    d.cues[2]!.start = 3650
    let logic = FakeLogic(d)
    logic.position = 3660
    logic.play()
    logic.advance(0.01)
    logic.note(37)          // Logic «догоняет» ноту в момент старта
    logic.advance(1)
    check(approx(d.cues[2]?.start, 3650), "Chase: метка не сдвинулась: \(String(describing: d.cues[2]?.start))")
    if case .song(2, let pos, true) = d.output(at: logic.now) {
        check(approx(pos, 11, 0.05), "Chase: видео с середины, а не с начала: \(pos)")
    } else { check(false, "Chase: должна идти песня 2") }
    // Метка, пройденная во время воспроизведения, обновляется
    d.cues[3]!.start = 3700
    logic.position = 3695
    logic.play()
    logic.advance(2)
    logic.note(38)
    check(approx(d.cues[3]?.start, 3697, 0.03), "Метку можно передвинуть в проекте: \(String(describing: d.cues[3]?.start))")
}

// 4в. Повторы кусочков MTC не ломают сборку
do {
    var decoder = MTCDecoder()
    let tc = Timecode(hours: 1, minutes: 0, seconds: 5, frames: 0, rate: .fps25)
    var result: (position: Double, rate: MTCRate)?
    for byte in MTCEncoder.quarterFrames(tc) {
        result = decoder.feed(byte) ?? result
        check(decoder.feed(byte) == nil, "Повтор кусочка игнорируется")
    }
    check(approx(result?.position, tc.realSeconds + 1.75 / 25), "Повторы MTC: позиция собирается")
}

// 5. Нет MTC вообще — нота запускает клип с начала
do {
    let d = makeDirector()
    let logic = FakeLogic(d)
    logic.note(38)
    logic.advance(2)
    if case .song(3, let pos, false) = d.output(at: logic.now) {
        check(approx(pos, 2, 0.02), "Без MTC: позиция по своим часам")
    } else { check(false, "Без MTC: нота должна запустить песню 3") }
    logic.advance(10)
    check(d.output(at: logic.now) == .logo, "Без MTC: в конце — логотип")
}

// 6. Ручные режимы
do {
    let d = makeDirector()
    d.manualBlack = true
    check(d.output(at: 0) == .black, "Ручной: затемнение")
    d.manualBlack = false
    d.manualLogo = true
    d.cues[1]!.start = 3600
    let logic = FakeLogic(d)
    logic.position = 3601
    logic.play()
    logic.advance(1)
    check(d.output(at: logic.now).isSong(1), "Ручной логотип сбрасывается стартом воспроизведения")
}

extension ShowOutput {
    func isSong(_ id: Int, locked: Bool? = nil) -> Bool {
        if case .song(let i, _, let l) = self { return i == id && (locked == nil || locked == l) }
        return false
    }
}

print(failures == 0 ? "✓ Все проверки пройдены (\(checks))" : "\(failures) из \(checks) проверок не прошли")
exit(failures == 0 ? 0 : 1)
