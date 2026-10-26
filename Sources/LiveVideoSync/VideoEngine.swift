import AVFoundation
import QuartzCore

/// Слот песни: свой AVPlayer и слой. Слотов два — текущая песня и подготовленная следующая.
final class SongSlot {
    let player = AVPlayer()
    let layer: AVPlayerLayer
    private(set) var cueId: Int?
    private(set) var url: URL?
    /// Начало видео после обрезки (Trim), с
    private(set) var startOffset = 0.0
    private(set) var started = false
    private var prerolled = false
    private var graceUntil = 0.0
    /// Расхождение видео с таймкодом (с), для монитора
    private(set) var drift: Double?
    private(set) var resyncCount = 0
    private var lastHardResync = -100.0
    /// Картинка вместо видео (слой поверх кадра видео)
    let imageLayer = CALayer()
    private(set) var image: CGImage?
    /// Загружена картинка (сама она распаковывается в фоне и появляется чуть позже)
    private(set) var isImage = false
    private var imageFailed = false
    /// Защита от устаревшей фоновой распаковки (слот успели перезагрузить)
    private var loadToken = 0

    init() {
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        player.preventsDisplaySleepDuringVideoPlayback = false
        layer = AVPlayerLayer(player: player)
        layer.opacity = 0
        imageLayer.contentsGravity = .resize
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(imageLayer)
    }

    /// Рамка на экране; картинка — во весь слой
    func setFrame(_ frame: CGRect) {
        if layer.frame != frame { layer.frame = frame }
        let inner = CGRect(origin: .zero, size: frame.size)
        if imageLayer.frame != inner { imageLayer.frame = inner }
    }

    /// Размер картинки или кадра видео (для рамки на экране)
    var contentSize: CGSize? {
        if let image { return CGSize(width: image.width, height: image.height) }
        return player.currentItem?.presentationSize
    }

    func load(id: Int, url: URL, start: Double = 0) {
        cueId = id
        self.url = url
        startOffset = start
        started = false
        prerolled = false
        drift = nil
        loadToken += 1
        image = nil
        imageLayer.contents = nil
        imageFailed = false
        isImage = Library.imageExtensions.contains(url.pathExtension.lowercased())
        if isImage {
            player.replaceCurrentItem(with: nil)
            // Распаковка большой картинки — не на главном потоке (там таймер синхронизации)
            let token = loadToken
            Self.decodeImage(url) { [weak self] image in
                guard let self, self.loadToken == token else { return }
                self.image = image
                self.imageLayer.contents = image
                self.imageFailed = image == nil
                if image == nil { Log.info("Слот: картинка не открывается — \(url.lastPathComponent)") }
            }
            Log.info("Слот: загружается картинка \(id) (\(url.lastPathComponent))")
            return
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        if start > 0 { player.seek(to: CMTime(seconds: start, preferredTimescale: 90_000), toleranceBefore: .zero, toleranceAfter: .zero) }
        Log.info("Слот: загружена песня \(id) (\(url.lastPathComponent))")
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Распаковать картинку в фоне, результат — на главном потоке
    static func decodeImage(_ url: URL, completion: @escaping (CGImage?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let image = loadImage(url)
            DispatchQueue.main.async { completion(image) }
        }
    }

    private var itemReady: Bool { player.currentItem?.status == .readyToPlay }

    private var duration: Double {
        let d = player.currentItem?.duration.seconds ?? 0
        return d.isFinite ? d : 0
    }

    /// Есть кадр на экране
    var isReady: Bool { isImage ? image != nil : (itemReady && layer.isReadyForDisplay) }

    var failed: Bool {
        isImage ? imageFailed : player.currentItem?.status == .failed
    }

    /// Длительность видео (без обрезки), с
    var videoDuration: Double { duration }

    /// Видео дошло до конца
    var reachedEnd: Bool {
        guard !isImage, itemReady, started else { return false }
        return player.currentTime().seconds >= duration - 0.05
    }

    /// Просто играть с начала (Extras), без таймкода
    func playFromStart() {
        started = true
        guard !isImage else { return }
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    /// Подготовка в фоне: декодер прогрет на первом кадре
    func idle() {
        guard !isImage, itemReady, !started, !prerolled else { return }
        prerolled = true
        player.preroll(atRate: 1) { _ in }
    }

    /// Держаться за позицию p (секунды от начала видео) в момент now
    func follow(position p: Double, now: Double) {
        if isImage {
            started = true
            return
        }
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
        url = nil
        loadToken += 1
        image = nil
        isImage = false
        imageFailed = false
        imageLayer.contents = nil
        started = false
        prerolled = false
        drift = nil
    }

    /// Ушла с экрана: остановить и вернуть на первый кадр — снова готова к старту
    func deactivate() {
        player.pause()
        guard !isImage else {
            started = false
            return
        }
        started = false
        prerolled = false
        drift = nil
        player.seek(to: CMTime(seconds: startOffset, preferredTimescale: 90_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// Логотип по кругу без шва
final class LogoPlayer {
    let player = AVQueuePlayer()
    let layer: AVPlayerLayer
    private var looper: AVPlayerLooper?
    private(set) var url: URL?
    /// Логотип-картинка (слой поверх кадра видео)
    let imageLayer = CALayer()
    private(set) var image: CGImage?
    private var imageFailed = false

    init() {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        layer = AVPlayerLayer(player: player)
        layer.opacity = 0
        imageLayer.contentsGravity = .resize
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(imageLayer)
    }

    func load(_ url: URL?) {
        guard url != self.url else { return }
        self.url = url
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        image = nil
        imageLayer.contents = nil
        imageFailed = false
        guard let url else { return }
        if Library.imageExtensions.contains(url.pathExtension.lowercased()) {
            SongSlot.decodeImage(url) { [weak self] image in
                guard let self, self.url == url else { return }
                self.image = image
                self.imageLayer.contents = image
                self.imageFailed = image == nil
                Log.info(image == nil ? "Логотип не открывается: \(url.lastPathComponent)" : "Логотип (картинка): \(url.lastPathComponent)")
            }
            return
        }
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
        Log.info("Логотип: \(url.lastPathComponent)")
    }

    /// Размер картинки или кадра (для рамки на экране)
    var contentSize: CGSize? {
        if let image { return CGSize(width: image.width, height: image.height) }
        return player.currentItem?.presentationSize
    }

    func setFrame(_ frame: CGRect) {
        if layer.frame != frame { layer.frame = frame }
        let inner = CGRect(origin: .zero, size: frame.size)
        if imageLayer.frame != inner { imageLayer.frame = inner }
    }

    /// Без файла логотипа «готов» сразу — показывается чёрный
    var isReady: Bool { url == nil || image != nil || layer.isReadyForDisplay }

    /// Файл логотипа не открывается
    var failed: Bool {
        guard url != nil else { return false }
        return imageFailed || looper?.status == .failed || player.currentItem?.status == .failed
    }
}

/// Видеодвижок: что видно на экране и плавные переходы между этим.
/// Новый клип выходит на экран только когда у него есть кадр — до этого виден прежний, без чёрных вспышек.
final class VideoEngine {
    enum Element: Equatable {
        case black, logo, slot(Int), extras
    }

    let rootLayer = CALayer()
    /// Всё, что идёт на экран (логотип, песни, Extras), — к этому слою применяется Screen Fit
    let contentLayer = CALayer()
    /// Обрезка (Crop) — маска контента
    private let cropMask = CALayer()
    /// Тестовая сетка поверх всего вывода и вместе с ним под Screen Fit:
    /// красная рамка = край картинки — видно, как она ложится на экран площадки
    let testPatternLayer = CALayer()
    let logo = LogoPlayer()
    let slots = [SongSlot(), SongSlot()]
    let extras = ExtrasPlayer()
    var fit = ScreenFit() { didSet { if fit != oldValue { applyFit() } } }
    var testPattern = false {
        didSet {
            guard testPattern != oldValue else { return }
            updateTestPattern()
        }
    }
    /// Подпись на сетке: экран и размер в пикселях
    /// Пикселей на точку у экрана вывода (подписи сетки — в пикселях)
    var pixelScale: CGFloat = 1
    var testPatternTitle = "" {
        didSet { if testPattern, testPatternTitle != oldValue { updateTestPattern() } }
    }
    var fadeOut = 0.7
    var fadeIn = 0.7
    var crossfade = false
    var urlForCue: (Int) -> URL? = { _ in nil }
    /// Начало видео песни после обрезки (Trim), с
    var startForCue: (Int) -> Double = { _ in 0 }

    private(set) var visible: Element = .black
    private var reportedBrokenLogo = false
    private var pendingFadeIn: (element: Element, notBefore: Double, since: Double)?
    private var fadingOutUntil: [Int: Double] = [:]

    init() {
        rootLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        // Пока экрана сцены нет — пропорции 16:9 (для превью)
        rootLayer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let noActions: [String: CAAction] = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                             "transform": NSNull(), "anchorPoint": NSNull(), "frame": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        contentLayer.actions = noActions
        contentLayer.anchorPoint = .zero
        cropMask.actions = noActions
        cropMask.backgroundColor = CGColor(gray: 1, alpha: 1)
        contentLayer.mask = cropMask
        rootLayer.addSublayer(contentLayer)
        for layer in [logo.layer] + slots.map(\.layer) {
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
            contentLayer.addSublayer(layer)
        }
        extras.container.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
        contentLayer.addSublayer(extras.container)
        testPatternLayer.actions = noActions
        testPatternLayer.isHidden = true
        testPatternLayer.contentsGravity = .resize
        contentLayer.addSublayer(testPatternLayer)
        rootLayer.masksToBounds = true
        applyFit()
        for layer in [logo.layer] + slots.map(\.layer) {
            layer.autoresizingMask = []
            layer.videoGravity = .resize
        }
    }

    var scale: ScaleMode = .fit {
        didSet { if scale != oldValue { layoutVideo() } }
    }

    func layout(bounds: CGRect) {
        let changed = rootLayer.bounds.size != bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.frame = bounds
        testPatternLayer.frame = rootLayer.bounds
        CATransaction.commit()
        if changed {
            applyFit()
            if testPattern { updateTestPattern() }
        }
        layoutVideo()
    }

    /// Screen Fit → один проективный transform слоя контента + маска обрезки
    private func applyFit() {
        let w = Double(rootLayer.bounds.width), h = Double(rootLayer.bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.bounds = rootLayer.bounds
        contentLayer.position = .zero
        let r = fit.cropRect(width: w, height: h)
        cropMask.frame = CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
        contentLayer.transform = fit.isIdentity ? CATransform3DIdentity
            : (fit.homography(width: w, height: h).map(Self.transform3D) ?? CATransform3DIdentity)
        CATransaction.commit()
    }

    /// Гомография 3×3 → CATransform3D (Core Animation умножает строку [x y z 1] на матрицу)
    static func transform3D(_ hm: [Double]) -> CATransform3D {
        var t = CATransform3DIdentity
        t.m11 = hm[0]; t.m12 = hm[3]; t.m14 = hm[6]
        t.m21 = hm[1]; t.m22 = hm[4]; t.m24 = hm[7]
        t.m41 = hm[2]; t.m42 = hm[5]; t.m44 = hm[8]
        return t
    }

    private func updateTestPattern() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        testPatternLayer.isHidden = !testPattern
        if testPattern { testPatternLayer.contents = TestPattern.image(size: rootLayer.bounds.size, title: testPatternTitle, pixelScale: pixelScale) }
        CATransaction.commit()
        Log.info("Test Pattern: \(testPattern ? "вкл" : "выкл")")
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Пока размер неизвестен — по пропорциям экрана, кадра всё равно ещё нет
        logo.setFrame(Self.videoFrame(videoSize: logo.contentSize ?? .zero, in: bounds, mode: scale))
        for slot in slots {
            slot.setFrame(Self.videoFrame(videoSize: slot.contentSize ?? .zero, in: bounds, mode: scale))
        }
        CATransaction.commit()
    }


    /// Видно ли сейчас Extras (или они ещё уходят с экрана)
    var extrasVisible: Bool {
        visible == .extras || (extras.container.presentation()?.opacity ?? extras.container.opacity) > 0.001
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
            // Битый логотип — не уводим в чёрное: остаётся то, что на экране (последний кадр песни)
            if logo.failed, visible != .black {
                if !reportedBrokenLogo { Log.info("Логотип не открывается — оставляю последний кадр"); reportedBrokenLogo = true }
            } else {
                show(.logo, now: now)
            }
        case .extras:
            show(.extras, now: now)
        case .song(let id, let position, _):
            if let i = slotIndex(holding: id) ?? acquireSlot(for: id) {
                // Битый файл — лучше логотип, чем чёрный экран
                if slots[i].failed {
                    show(.logo, now: now)
                    break
                }
                slots[i].follow(position: position + slots[i].startOffset, now: now)
                show(.slot(i), now: now)
            } else {
                show(.logo, now: now)
            }
        }

        layoutVideo()
        extras.layout(bounds: rootLayer.bounds, scale: scale)

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
            slots[i].load(id: next, url: url, start: startForCue(next))
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
        // И номер, и файл, и начало: после перестановки песен номер 3 — уже другой файл,
        // после Trim — другое начало
        let url = urlForCue(id)
        let start = startForCue(id)
        // Без проверки «есть видео»: у картинки его нет, и иначе она перезагружалась бы на каждом кадре
        return slots.firstIndex {
            $0.cueId == id && $0.url != nil && $0.url == url && abs($0.startOffset - start) < 0.001
        }
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
        slots[i].load(id: id, url: url, start: startForCue(id))
        return i
    }

    private func layer(for element: Element) -> CALayer? {
        switch element {
        case .black: return nil
        case .logo: return logo.layer
        case .slot(let i): return slots[i].layer
        case .extras: return extras.container
        }
    }

    private func isReady(_ element: Element) -> Bool {
        switch element {
        case .black: return true
        case .logo: return logo.isReady
        case .slot(let i): return slots[i].isReady && slots[i].started
        case .extras: return extras.isReady
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
        case .extras: return "Extras"
        }
    }
}


/// Превью в окне управления: те же плееры, что и на экране сцены, — второй набор слоёв.
/// Каждый кадр копирует прозрачность, рамки, картинки и Screen Fit с экрана сцены, масштабируя под свой размер.
final class PreviewMirror {
    private struct Pair {
        let source: AVPlayerLayer
        let mirror: AVPlayerLayer
        let image: CALayer?
        let sourceImage: CALayer?
        /// Прозрачность родителя (контейнер Extras)
        let parent: CALayer?
    }

    let rootLayer = CALayer()
    /// Холст размером с экран сцены, уменьшенный до размера превью
    private let canvas = CALayer()
    private let content = CALayer()
    private let cropMask = CALayer()
    private let testPattern = CALayer()
    private let engine: VideoEngine
    private let pairs: [Pair]

    init(engine: VideoEngine) {
        self.engine = engine
        rootLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        rootLayer.masksToBounds = true
        let noActions: [String: CAAction] = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull(), "contents": NSNull(),
                                             "transform": NSNull(), "anchorPoint": NSNull(), "frame": NSNull(), "hidden": NSNull()]
        for l in [canvas, content, cropMask, testPattern] { l.actions = noActions }
        canvas.anchorPoint = .zero
        content.anchorPoint = .zero
        cropMask.backgroundColor = CGColor(gray: 1, alpha: 1)
        content.mask = cropMask
        testPattern.contentsGravity = .resize
        rootLayer.addSublayer(canvas)
        canvas.addSublayer(content)
        func pair(_ source: AVPlayerLayer, slot: SongSlot?, parent: CALayer?, image sourceImage: CALayer? = nil) -> Pair {
            let mirror = AVPlayerLayer(player: source.player)
            mirror.videoGravity = .resize
            mirror.opacity = 0
            mirror.actions = noActions
            var image: CALayer?
            if slot != nil || sourceImage != nil {
                // У AVPlayerLayer свои внутренние слои — картинку берём прямо из слота
                let l = CALayer()
                l.contentsGravity = .resize
                l.actions = noActions
                mirror.addSublayer(l)
                image = l
            }
            return Pair(source: source, mirror: mirror, image: image, sourceImage: sourceImage ?? slot?.imageLayer, parent: parent)
        }
        pairs = [pair(engine.logo.layer, slot: nil, parent: nil, image: engine.logo.imageLayer)]
            + engine.slots.map { pair($0.layer, slot: $0, parent: nil) }
            + engine.extras.slots.map { pair($0.layer, slot: $0, parent: engine.extras.container) }
        for p in pairs { content.addSublayer(p.mirror) }
        content.addSublayer(testPattern)
        rootLayer.actions = ["bounds": NSNull(), "position": NSNull()]
    }

    /// Пропорции экрана сцены (для рамки превью)
    var aspect: CGFloat {
        let b = engine.rootLayer.bounds
        return b.height > 0 ? b.width / b.height : 16 / 9
    }

    func sync() {
        let src = engine.rootLayer.bounds
        let dst = rootLayer.bounds
        guard src.width > 0, src.height > 0, dst.width > 0 else { return }
        let k = dst.width / src.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if canvas.bounds != src { canvas.bounds = src }
        canvas.position = .zero
        let scale = CATransform3DMakeScale(k, k, 1)
        if !CATransform3DEqualToTransform(canvas.transform, scale) { canvas.transform = scale }
        if content.bounds != src { content.bounds = src }
        content.position = .zero
        if !CATransform3DEqualToTransform(content.transform, engine.contentLayer.transform) {
            content.transform = engine.contentLayer.transform
        }
        if let mask = engine.contentLayer.mask, cropMask.frame != mask.frame { cropMask.frame = mask.frame }
        testPattern.frame = src
        if testPattern.isHidden != engine.testPatternLayer.isHidden { testPattern.isHidden = engine.testPatternLayer.isHidden }
        if (testPattern.contents as AnyObject?) !== (engine.testPatternLayer.contents as AnyObject?) {
            testPattern.contents = engine.testPatternLayer.contents
        }
        for p in pairs {
            if p.mirror.frame != p.source.frame { p.mirror.frame = p.source.frame }
            var opacity = p.source.presentation()?.opacity ?? p.source.opacity
            if let parent = p.parent { opacity *= parent.presentation()?.opacity ?? parent.opacity }
            if p.mirror.opacity != opacity { p.mirror.opacity = opacity }
            if let image = p.image {
                let contents = p.sourceImage?.contents
                if (image.contents as AnyObject?) !== (contents as AnyObject?) { image.contents = contents }
                if image.frame != p.mirror.bounds { image.frame = p.mirror.bounds }
            }
        }
        CATransaction.commit()
    }
}
