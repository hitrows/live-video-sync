import AVFoundation
import QuartzCore

/// Плеер Extras: плейлист по порядку или один файл. Два слоя — следующий файл готовится заранее,
/// переход плавный. У видео Extras есть звук (у песен сет-листа звука нет — он из Logic).
final class ExtrasPlayer {
    struct Entry: Equatable {
        let url: URL
        let isImage: Bool
    }

    enum Mode: Equatable {
        /// Плейлист с повтором
        case playlist(RepeatMode)
        /// ▶ у строки: видео — до конца, потом логотип; картинка — бесконечно
        case single
    }

    let container = CALayer()
    let slots = [SongSlot(), SongSlot()]
    var imageDuration = 10.0
    var crossfade = 0.5
    var volume: Float = 1 { didSet { slots.forEach { $0.player.volume = volume } } }
    var audioDevice: String? { didSet { slots.forEach { $0.player.audioOutputDeviceUniqueID = audioDevice } } }
    /// Вывод выключен (Stop Output) — звук Extras тоже не нужен
    var muted = false { didSet { slots.forEach { $0.player.isMuted = muted } } }
    /// Плейлист доиграл (Repeat Off) или одиночное видео кончилось
    var onFinished: () -> Void = {}

    private(set) var entries: [Entry] = []
    private(set) var index = 0
    private(set) var mode: Mode = .single
    private(set) var isPlaying = false
    /// Слот на экране
    private var current = 0
    private var shownAt = 0.0
    /// Следующий файл загружен во второй слот и ждёт своей очереди
    private var preparedIndex: Int?
    private var switching = false
    /// Номер запуска: отложенная пауза старого слоя не должна задеть новый запуск
    private var generation = 0
    /// Файлы, которые не открылись (диск отключили, файл удалили), — пропускаем
    private var broken: Set<Int> = []
    /// С какого момента ждём, пока следующий файл будет готов (держим последний кадр текущего)
    private var waitingSince: Double?
    /// Дольше не ждём: файл, видимо, не откроется
    private let readyTimeout = 5.0

    init() {
        container.opacity = 0
        container.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
        for slot in slots {
            slot.player.isMuted = false
            slot.layer.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
            container.addSublayer(slot.layer)
        }
    }

    var currentSlot: SongSlot { slots[current] }
    var currentEntry: Entry? { entries.indices.contains(index) ? entries[index] : nil }

    /// Готов показать первый кадр
    var isReady: Bool { isPlaying && currentSlot.isReady }

    func play(_ entries: [Entry], from index: Int = 0, mode: Mode, now: Double) {
        guard entries.indices.contains(index) else { return }
        self.entries = entries
        self.index = index
        self.mode = mode
        generation += 1
        isPlaying = true
        preparedIndex = nil
        switching = false
        broken = []
        waitingSince = nil
        for slot in slots { slot.player.pause() }
        current = 0
        load(slot: 0, index: index)
        slots[0].layer.opacity = 1
        slots[1].layer.opacity = 0
        slots[0].playFromStart()
        shownAt = now
        Log.info("Extras: \(entries[index].url.lastPathComponent) (\(describe(mode)))")
    }

    func stop() {
        guard isPlaying else { return }
        isPlaying = false
        generation += 1
        for slot in slots {
            slot.player.pause()
            slot.unload()
        }
        preparedIndex = nil
        Log.info("Extras: остановлены")
    }

    /// Repeat поменяли, пока плейлист играет — сразу действует
    func setRepeat(_ r: RepeatMode) {
        guard isPlaying, case .playlist = mode else { return }
        mode = .playlist(r)
        Log.info("Extras: повтор \(r.title)")
    }

    /// Картинки плейлиста сменяются по времени (в Repeat One и одиночном показе висят бесконечно)
    private var imagesAdvance: Bool { mode == .playlist(.off) || mode == .playlist(.all) }

    /// Положение текущего файла (для Now Playing)
    func position(at now: Double) -> Double {
        currentSlot.isImage ? max(0, now - shownAt) : max(0, currentSlot.player.currentTime().seconds)
    }

    var duration: Double {
        currentSlot.isImage ? (imagesAdvance ? imageDuration : 0) : currentSlot.videoDuration
    }

    func tick(now: Double) {
        guard isPlaying, let entry = currentEntry else { return }
        let slot = currentSlot
        if slot.failed, !broken.contains(index) {
            broken.insert(index)
            Log.info("Extras: файл не открывается — пропускаю \(entry.url.lastPathComponent)")
        }
        // Видео ещё не началось (не было готово) — запустить, как только готово
        if !entry.isImage, !slot.started, !slot.failed { slot.playFromStart() }

        let finished: Bool
        if slot.failed {
            finished = true
        } else if entry.isImage {
            switch mode {
            case .single, .playlist(.one): finished = false
            case .playlist: finished = now - shownAt >= imageDuration
            }
        } else {
            finished = slot.reachedEnd
        }

        if let next = nextIndex(), preparedIndex != next, !switching {
            load(slot: 1 - current, index: next)
            preparedIndex = next
        }
        // Подготовленный файл не открылся — пропустить, на следующем тике подготовится другой
        if let p = preparedIndex, !switching, slots[1 - current].failed {
            broken.insert(p)
            preparedIndex = nil
            Log.info("Extras: файл не открывается — пропускаю \(entries[p].url.lastPathComponent)")
        }

        guard finished, !switching else { return }
        if !slot.failed, mode == .playlist(.one) || (mode == .playlist(.all) && entries.count == 1) {
            // По кругу один файл — с начала, без перехода
            slot.playFromStart()
            shownAt = now
            return
        }
        guard let next = nextIndex() else {
            Log.info("Extras: доиграли")
            onFinished()
            return
        }
        guard preparedIndex == next else { return }
        // Следующий ещё без кадра — держим последний кадр текущего, а не уходим в пустоту
        if !slots[1 - current].isReady {
            let since = waitingSince ?? now
            waitingSince = since
            guard now - since >= readyTimeout else { return }
            Log.info("Extras: \(entries[next].url.lastPathComponent) не готов за \(Int(readyTimeout)) с — пропускаю")
            broken.insert(next)
            preparedIndex = nil
            waitingSince = nil
            return
        }
        waitingSince = nil
        switchTo(next, now: now)
    }

    /// Следующий файл, пропуская неоткрывшиеся
    private func nextIndex() -> Int? {
        var i = index
        for _ in 0..<entries.count {
            switch mode {
            case .single, .playlist(.one): return nil
            case .playlist(.off):
                guard i + 1 < entries.count else { return nil }
                i += 1
            case .playlist(.all):
                i = (i + 1) % entries.count
            }
            if !broken.contains(i) { return i }
        }
        return nil
    }

    private func switchTo(_ next: Int, now: Double) {
        let incoming = slots[1 - current]
        let outgoing = currentSlot
        switching = true
        incoming.playFromStart()
        fade(incoming.layer, to: 1)
        fade(outgoing.layer, to: 0)
        let old = current
        current = 1 - current
        index = next
        shownAt = now
        preparedIndex = nil
        let gen = generation
        Log.info("Extras: \(entries[next].url.lastPathComponent)")
        DispatchQueue.main.asyncAfter(deadline: .now() + crossfade) { [weak self] in
            // Успели запустить другой плейлист — этот слой уже чужой, не трогаем
            guard let self, self.generation == gen else { return }
            self.slots[old].player.pause()
            self.switching = false
        }
    }

    private func load(slot i: Int, index: Int) {
        slots[i].load(id: index + 1, url: entries[index].url)
        slots[i].player.isMuted = muted
        slots[i].player.volume = volume
        slots[i].player.audioOutputDeviceUniqueID = audioDevice
    }

    private func fade(_ layer: CALayer, to value: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = value
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = value
        a.duration = crossfade
        layer.add(a, forKey: "fade")
        CATransaction.commit()
    }

    func layout(bounds: CGRect, scale: ScaleMode) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if container.frame != bounds { container.frame = bounds }
        for slot in slots {
            slot.setFrame(VideoEngine.videoFrame(videoSize: slot.contentSize ?? .zero, in: bounds, mode: scale))
        }
        CATransaction.commit()
    }

    private func describe(_ mode: Mode) -> String {
        switch mode {
        case .single: return "один файл"
        case .playlist(let r): return "плейлист, повтор \(r.title)"
        }
    }
}
