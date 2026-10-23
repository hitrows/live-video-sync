import Foundation

/// Песня из папки с видео
struct CueInfo: Equatable {
    let id: Int
    let duration: Double
    /// Начало песни в проекте Logic (секунды MTC) — выучено по ноте-метке
    var start: Double?
}

/// Что должно быть на экране прямо сейчас
enum ShowOutput: Equatable {
    case black
    case logo
    /// locked — видео держится за таймкод Logic; иначе доигрывает само (связь пропала или MTC нет)
    case song(id: Int, position: Double, locked: Bool)
}

/// Логика шоу: из MIDI (MTC, MMC, ноты-метки) решает, что показывать.
/// Без AppKit и AVFoundation — проверяется тестами.
final class Director {
    var cues: [Int: CueInfo] = [:]
    /// Песня уходит в fade-out так, чтобы закончить его ровно к концу видео
    var fadeOut: Double = 0.7
    /// Нота-метка первой песни; песня N — markerBaseNote + N - 1
    var markerBaseNote = 36
    var manualBlack = false
    /// Ручной логотип; сбрасывается новой нотой-меткой или стартом воспроизведения
    var manualLogo = false
    /// Выучено начало песни: (id, позиция MTC)
    var onCueLearned: ((Int, Double) -> Void)?

    private(set) var clock = MTCClock()
    private var decoder = MTCDecoder()
    private(set) var stoppedByMMC = false
    private var freeRun: (id: Int, position: Double, host: Double)?
    /// Нота пришла, когда MTC уже идёт, но полного кода ещё нет (старт ровно с метки)
    private var pendingMarker: (id: Int, host: Double)?
    private(set) var lastMessageHost: Double?
    /// Когда началось текущее воспроизведение (первый кусочек MTC после паузы)
    private var playbackStartHost: Double?
    /// Последний MMC Locate: если после него таймкод замолчал — Logic остановили (а не связь пропала)
    private var lastLocateHost: Double?
    private(set) var lastSongId: Int?
    private(set) var lastKnownPosition: Double?

    func id(forNote note: Int) -> Int { note - markerBaseNote + 1 }
    func note(forId id: Int) -> Int { markerBaseNote + id - 1 }

    func handle(_ event: MIDIEvent, host: Double) {
        lastMessageHost = host
        switch event {
        case .quarterFrame(let byte):
            if !clock.isReceiving(at: host) {
                // Воспроизведение началось (или связь вернулась)
                clock.reset()
                decoder.reset()
                stoppedByMMC = false
                manualLogo = false
                playbackStartHost = host
            }
            clock.noteQuarterFrame(host: host)
            if let full = decoder.feed(byte) {
                clock.addAnchor(position: full.position, host: host, rate: full.rate)
                if let pending = pendingMarker, let pos = clock.extrapolatedPosition(at: pending.host) {
                    learnIfMarker(pending.id, at: pos, host: pending.host)
                    pendingMarker = nil
                }
            }

        case .noteOn(_, let note, _):
            let id = id(forNote: Int(note))
            guard cues[id] != nil else { return }
            manualLogo = false
            if clock.isReceiving(at: host) {
                if let pos = clock.position(at: host) {
                    learnIfMarker(id, at: pos, host: host)
                } else {
                    pendingMarker = (id, host)
                }
            } else {
                // Таймкода нет — просто играем клип с начала
                freeRun = (id, 0, host)
                stoppedByMMC = false
            }

        case .sysex(let payload):
            switch MTCSysex.parse(payload) {
            case .mmcStop, .mmcPause:
                stoppedByMMC = true
                clock.stop()
                freeRun = nil
            case .mmcLocate(let position):
                lastLocateHost = host
                lastKnownPosition = position
            case .fullFrame(let position, _):
                lastKnownPosition = position
            default:
                break
            }
        }
    }

    /// Защита от Chase в Logic: Play с середины длинной ноты-метки — Logic шлёт её заново в момент старта.
    /// Если нота пришла в первые 0.3 с воспроизведения, а песня уже известна и началась раньше —
    /// это не начало песни, метку не трогаем.
    private func learnIfMarker(_ id: Int, at position: Double, host: Double) {
        if let started = playbackStartHost, host - started < 0.3,
           let cue = cues[id], let start = cue.start,
           position - start > 0.5, position < start + cue.duration {
            return
        }
        learn(id, at: position)
    }

    private func learn(_ id: Int, at position: Double) {
        guard var cue = cues[id] else { return }
        if let old = cue.start, abs(old - position) < 0.02 { return }
        cue.start = position
        cues[id] = cue
        onCueLearned?(id, position)
    }

    func visibleEnd(_ cue: CueInfo) -> Double {
        max(0.1, cue.duration - fadeOut)
    }

    /// Песня, внутри которой позиция Logic; если метки перекрываются — более поздняя
    func cue(at position: Double) -> (id: Int, offset: Double)? {
        var best: (id: Int, offset: Double, start: Double)?
        for cue in cues.values {
            guard let start = cue.start, position >= start, position < start + visibleEnd(cue) else { continue }
            if best == nil || start > best!.start {
                best = (cue.id, position - start, start)
            }
        }
        return best.map { ($0.id, $0.offset) }
    }

    func output(at now: Double) -> ShowOutput {
        if manualBlack { return .black }
        if manualLogo { return .logo }

        if let pos = clock.position(at: now) {
            lastKnownPosition = pos
            freeRun = nil
            if let hit = cue(at: pos) {
                lastSongId = hit.id
                return .song(id: hit.id, position: hit.offset, locked: true)
            }
            return .logo
        }

        if stoppedByMMC { return .logo }

        // Таймкод замолчал сразу после Locate — это стоп в Logic
        if let locate = lastLocateHost, let lastQF = clock.lastQuarterFrameHost, locate >= lastQF - 0.1 {
            stoppedByMMC = true
            freeRun = nil
            clock.reset()
            return .logo
        }

        // Таймкод пропал без команды «Стоп» — песня доигрывает сама до конца
        if freeRun == nil, clock.hasAnchor, let pos = clock.extrapolatedPosition(at: now), let hit = cue(at: pos) {
            freeRun = (hit.id, hit.offset, now)
        }
        // Замеры больше не нужны: при возврате таймкода часы начнут заново
        clock.reset()
        if let run = freeRun, let cue = cues[run.id] {
            let position = run.position + (now - run.host)
            if position < visibleEnd(cue) {
                lastSongId = run.id
                return .song(id: run.id, position: position, locked: false)
            }
            freeRun = nil
        }
        return .logo
    }

    /// Какую песню держать наготове во втором слоте
    func nextCue(after output: ShowOutput) -> Int? {
        let ids = cues.keys.sorted()
        guard !ids.isEmpty else { return nil }
        if case .song(let id, _, _) = output {
            return ids.first { $0 > id }
        }
        if let pos = lastKnownPosition {
            let upcoming = cues.values
                .compactMap { cue in cue.start.map { (cue.id, $0) } }
                .filter { $0.1 > pos - 0.5 }
                .min { $0.1 < $1.1 }
            if let upcoming { return upcoming.0 }
        }
        if let last = lastSongId, let next = ids.first(where: { $0 > last }) {
            return next
        }
        return ids.first
    }
}
