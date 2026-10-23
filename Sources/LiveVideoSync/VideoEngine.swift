import AVFoundation
import QuartzCore

/// Слот песни: свой AVPlayer и слой. Слотов два — текущая песня и подготовленная следующая.
final class SongSlot {
    let player = AVPlayer()
    let layer: AVPlayerLayer
    private(set) var cueId: Int?
    private(set) var started = false
    private var prerolled = false
    private var graceUntil = 0.0
    /// Расхождение видео с таймкодом (с), для монитора
    private(set) var drift: Double?
    private(set) var resyncCount = 0
    private var lastHardResync = -100.0

    init() {
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        player.preventsDisplaySleepDuringVideoPlayback = false
        layer = AVPlayerLayer(player: player)
        layer.opacity = 0
    }

    func load(id: Int, url: URL) {
        cueId = id
        started = false
        prerolled = false
        drift = nil
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        Log.info("Слот: загружена песня \(id) (\(url.lastPathComponent))")
    }

    private var itemReady: Bool { player.currentItem?.status == .readyToPlay }

    private var duration: Double {
        let d = player.currentItem?.duration.seconds ?? 0
        return d.isFinite ? d : 0
    }

    /// Есть кадр на экране
    var isReady: Bool { itemReady && layer.isReadyForDisplay }

    var failed: Bool { player.currentItem?.status == .failed }

    /// Подготовка в фоне: декодер прогрет на первом кадре
    func idle() {
        guard itemReady, !started, !prerolled else { return }
        prerolled = true
        player.preroll(atRate: 1) { _ in }
    }

    /// Держаться за позицию p (секунды от начала видео) в момент now
    func follow(position p: Double, now: Double) {
        guard itemReady else { return }
        let end = duration
        if !started || (player.rate == 0 && p < end - 0.1) {
            if p < end - 0.05 { start(at: p, now: now) }
            return
        }
        guard now >= graceUntil, player.rate != 0 else { return }
        let diff = player.currentTime().seconds - p
        drift = diff
        // Недавно уже перематывали — значит, файл тяжёлый: допуск шире и пауза дольше, чтобы не застрять в перемотках
        let recent = now - lastHardResync < 3
        if abs(diff) > (recent ? 0.5 : 0.25) {
            Log.info("Слот \(cueId ?? 0): расхождение \(Int(diff * 1000)) мс — пересинхронизация\(recent ? " (повторная)" : "")")
            resyncCount += 1
            start(at: p, now: now)
            if recent { graceUntil = now + 2 }
            lastHardResync = now
        } else if abs(diff) > 0.04 {
            // Мягкая подстройка скоростью — без рывка
            player.rate = Float(1 - max(-0.05, min(0.05, diff / 2)))
        } else if abs(diff) < 0.015, player.rate != 1 {
            player.rate = 1
        }
    }

    private func start(at p: Double, now: Double) {
        let lead = 0.06
        player.setRate(1, time: CMTime(seconds: p + lead, preferredTimescale: 90_000),
                       atHostTime: HostTime.cmTime(now + lead))
        started = true
        prerolled = false
        graceUntil = now + 0.6
    }

    func unload() {
        player.replaceCurrentItem(with: nil)
        cueId = nil
        started = false
        prerolled = false
        drift = nil
    }

    /// Ушла с экрана: остановить и вернуть на первый кадр — снова готова к старту
    func deactivate() {
        player.pause()
        started = false
        prerolled = false
        drift = nil
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// Логотип по кругу без шва
final class LogoPlayer {
    let player = AVQueuePlayer()
    let layer: AVPlayerLayer
    private var looper: AVPlayerLooper?
    private(set) var url: URL?

    init() {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        layer = AVPlayerLayer(player: player)
        layer.opacity = 0
    }

    func load(_ url: URL?) {
        guard url != self.url else { return }
        self.url = url
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        guard let url else { return }
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
        Log.info("Логотип: \(url.lastPathComponent)")
    }

    /// Без файла логотипа «готов» сразу — показывается чёрный
    var isReady: Bool { url == nil || layer.isReadyForDisplay }
}

/// Видеодвижок: что видно на экране и плавные переходы между этим.
/// Новый клип выходит на экран только когда у него есть кадр — до этого виден прежний, без чёрных вспышек.
final class VideoEngine {
    enum Element: Equatable {
        case black, logo, slot(Int)
    }

    let rootLayer = CALayer()
    let logo = LogoPlayer()
    let slots = [SongSlot(), SongSlot()]
    var fadeOut = 0.7
    var fadeIn = 0.7
    var crossfade = false
    var urlForCue: (Int) -> URL? = { _ in nil }

    private(set) var visible: Element = .black
    private var pendingFadeIn: (element: Element, notBefore: Double, since: Double)?
    private var fadingOutUntil: [Int: Double] = [:]

    init() {
        rootLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        for layer in [logo.layer] + slots.map(\.layer) {
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
            rootLayer.addSublayer(layer)
        }
        rootLayer.masksToBounds = true
        for layer in [logo.layer] + slots.map(\.layer) {
            layer.autoresizingMask = []
            layer.videoGravity = .resize
        }
    }

    var scale: ScaleMode = .fit {
        didSet { if scale != oldValue { layoutVideo() } }
    }

    func layout(bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.frame = bounds
        CATransaction.commit()
        layoutVideo()
    }

    /// Рамка видео по режиму масштаба: всегда с пропорциями видео, центр по экрану.
    /// Что не влезает в экран — обрезается (rootLayer.masksToBounds), где не хватает — чёрное поле.
    static func videoFrame(videoSize: CGSize, in bounds: CGRect, mode: ScaleMode) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let sx = bounds.width / videoSize.width
        let sy = bounds.height / videoSize.height
        let k: CGFloat
        switch mode {
        case .fit: k = min(sx, sy)
        case .fill: k = max(sx, sy)
        case .fitHeight: k = sy
        case .fitWidth: k = sx
        }
        let w = videoSize.width * k, h = videoSize.height * k
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// Пересчитать рамки (смена режима, экрана или нового файла с другими пропорциями)
    private func layoutVideo() {
        let bounds = rootLayer.bounds
        let items: [(AVPlayerLayer, CGSize?)] = [(logo.layer, logo.player.currentItem?.presentationSize)]
            + slots.map { ($0.layer, $0.player.currentItem?.presentationSize) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, size) in items {
            // Пока размер неизвестен — по пропорциям экрана, кадра всё равно ещё нет
            let frame = Self.videoFrame(videoSize: size ?? .zero, in: bounds, mode: scale)
            if layer.frame != frame { layer.frame = frame }
        }
        CATransaction.commit()
    }

    /// Активная песня (для монитора)
    var activeSlot: SongSlot? {
        if case .slot(let i) = visible { return slots[i] }
        return nil
    }

    func update(_ output: ShowOutput, next: Int?, now: Double) {
        switch output {
        case .black:
            show(.black, now: now)
        case .logo:
            show(.logo, now: now)
        case .song(let id, let position, _):
            if let i = slotIndex(holding: id) ?? acquireSlot(for: id) {
                // Битый файл — лучше логотип, чем чёрный экран
                if slots[i].failed {
                    show(.logo, now: now)
                    break
                }
                slots[i].follow(position: position, now: now)
                show(.slot(i), now: now)
            } else {
                show(.logo, now: now)
            }
        }

        layoutVideo()

        // Ушедшие с экрана слоты — остановить после fade-out, остальные — подготовить
        for (i, slot) in slots.enumerated() where visible != .slot(i) {
            if let until = fadingOutUntil[i] {
                if now >= until {
                    slot.deactivate()
                    fadingOutUntil[i] = nil
                }
            } else {
                slot.idle()
            }
        }

        // Следующая песня — заранее во втором слоте
        if let next, slotIndex(holding: next) == nil, let i = freeSlotIndex(), let url = urlForCue(next) {
            slots[i].load(id: next, url: url)
        }

        if let pending = pendingFadeIn, now >= pending.notBefore {
            if isReady(pending.element) {
                fade(layer(for: pending.element), to: 1, duration: fadeIn)
                pendingFadeIn = nil
            } else if case .slot(let i) = pending.element, slots[i].failed {
                Log.info("Песня \(slots[i].cueId ?? 0): файл не открывается — \(slots[i].player.currentItem?.error?.localizedDescription ?? "?")")
                pendingFadeIn = nil
            }
        }
    }

    /// Сбросить слоты (папка с видео поменялась)
    func reloadSongs() {
        for (i, slot) in slots.enumerated() where visible != .slot(i) {
            slot.unload()
            fade(slot.layer, to: 0, duration: 0)
            fadingOutUntil[i] = nil
        }
    }

    private func slotIndex(holding id: Int) -> Int? {
        slots.firstIndex { $0.cueId == id && $0.player.currentItem != nil }
    }

    /// Свободный слот: не на экране, не уходит в fade-out
    private func freeSlotIndex() -> Int? {
        slots.indices.first { i in
            visible != .slot(i) && fadingOutUntil[i] == nil && pendingFadeIn?.element != .slot(i)
        }
    }

    /// Слот под песню, которой нет ни в одном слоте (прыжок в Logic на неподготовленную песню)
    private func acquireSlot(for id: Int) -> Int? {
        guard let url = urlForCue(id) else { return nil }
        let i = freeSlotIndex() ?? slots.indices.first { visible != .slot($0) } ?? 0
        if fadingOutUntil[i] != nil {
            fade(slots[i].layer, to: 0, duration: 0)
            fadingOutUntil[i] = nil
        }
        slots[i].load(id: id, url: url)
        return i
    }

    private func layer(for element: Element) -> CALayer? {
        switch element {
        case .black: return nil
        case .logo: return logo.layer
        case .slot(let i): return slots[i].layer
        }
    }

    private func isReady(_ element: Element) -> Bool {
        switch element {
        case .black: return true
        case .logo: return logo.isReady
        case .slot(let i): return slots[i].isReady && slots[i].started
        }
    }

    private func show(_ target: Element, now: Double) {
        guard target != visible else { return }
        let outgoing = visible
        visible = target
        Log.info("Экран: \(describe(outgoing)) → \(describe(target))")

        var outDuration = 0.0
        if let outLayer = layer(for: outgoing) {
            let opacity = Double(outLayer.presentation()?.opacity ?? outLayer.opacity)
            outDuration = fadeOut * opacity
            fade(outLayer, to: 0, duration: fadeOut)
            if case .slot(let i) = outgoing { fadingOutUntil[i] = now + outDuration }
        }
        if case .slot(let i) = target { fadingOutUntil[i] = nil }

        pendingFadeIn = nil
        if target != .black {
            pendingFadeIn = (target, now + (crossfade ? 0 : outDuration), now)
        }
    }

    private func fade(_ layer: CALayer?, to value: Float, duration: Double) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "fade")
        layer.opacity = value
        if duration > 0.01, from != value {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = from
            animation.toValue = value
            animation.duration = duration * Double(abs(value - from))
            layer.add(animation, forKey: "fade")
        }
        CATransaction.commit()
    }

    private func describe(_ e: Element) -> String {
        switch e {
        case .black: return "чёрный"
        case .logo: return "логотип"
        case .slot(let i): return "песня \(slots[i].cueId ?? 0)"
        }
    }
}

