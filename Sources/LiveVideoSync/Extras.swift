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
        isPlaying = true
        preparedIndex = nil
        switching = false
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
        for slot in slots {
            slot.player.pause()
            slot.unload()
        }
        preparedIndex = nil
        Log.info("Extras: остановлены")
    }

    /// Положение текущего видео (для Now Playing)
    var position: Double {
        currentSlot.isImage ? 0 : max(0, currentSlot.player.currentTime().seconds)
    }

    var duration: Double {
        currentSlot.isImage ? 0 : currentSlot.videoDuration
    }

    func tick(now: Double) {
        guard isPlaying, let entry = currentEntry else { return }
        let slot = currentSlot
        // Видео ещё не началось (не было готово) — запустить, как только готово
        if !entry.isImage, !slot.started { slot.playFromStart() }

        let finished: Bool
        if entry.isImage {
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

        guard finished, !switching else { return }
        if mode == .playlist(.one) || (mode == .playlist(.all) && entries.count == 1) {
            // По кругу один файл — с начала, без перехода
            slot.playFromStart()
            shownAt = now
            return
        }
        guard let next = nextIndex(), preparedIndex == next else {
            Log.info("Extras: доиграли")
            onFinished()
            return
        }
        switchTo(next, now: now)
    }

    private func nextIndex() -> Int? {
        switch mode {
        case .single, .playlist(.one): return nil
        case .playlist(.off): return index + 1 < entries.count ? index + 1 : nil
        case .playlist(.all): return entries.isEmpty ? nil : (index + 1) % entries.count
        }
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
        Log.info("Extras: \(entries[next].url.lastPathComponent)")
        DispatchQueue.main.asyncAfter(deadline: .now() + crossfade) { [weak self] in
            guard let self else { return }
            self.slots[old].player.pause()
            self.switching = false
        }
    }

    private func load(slot i: Int, index: Int) {
        slots[i].load(id: index + 1, url: entries[index].url)
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
