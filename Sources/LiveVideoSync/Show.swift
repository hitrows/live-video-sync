import AppKit
import Combine
import IOKit.pwr_mgt

/// Блок Now Playing
struct NowPlaying: Equatable {
    enum Mode: Equatable {
        case logo, black
        /// Держится за таймкод Logic
        case locked
        /// Связь пропала — доигрывает само
        case free
        /// Ручной запуск
        case manual
        /// Плейлист Extras или одиночный файл Extras
        case extras
    }
    var mode: Mode = .logo
    var itemID: UUID?
    var number: Int?
    var title = ""
    var duration = 0.0
    /// Extras: «Band Logos · Repeat All»
    var extrasSource: String?
    var isImage = false
    /// «08 Song · marker G#1»
    var next: String?
}

/// Связь с Logic для строки статуса и баннеров
struct LogicStatus: Equatable {
    enum State: Equatable {
        /// Таймкод идёт или связь есть
        case connected
        /// Ещё не было связи (запуск, Logic Mac не выбран)
        case waiting
        /// Связь была и пропала
        case lost
        /// На этом Mac нет сетевого MIDI-сеанса
        case noSession
    }
    var state: State = .waiting
    var macName: String?
    var fps: String?
    var mtcRunning = false
    /// Выбранный источник сейчас виден в сети
    var visible = true

    /// «Logic: MacBook Pro Hitrows · connected · 01:07:32:14 · 24 fps»
    var line: String {
        switch state {
        case .noSession: return "Waiting for timecode · no network MIDI session"
        case .waiting:
            guard let macName else { return "Waiting for timecode" }
            return "Source: \(macName) · " + (visible ? "connecting…" : "not on the network")
        case .lost: return "Source: \(macName ?? "source Mac") · connection lost"
        case .connected:
            return "Source: \(macName ?? "connected") · connected"
        }
    }
}

/// Быстро меняющееся — позиция песни, расхождение, таймкод. Отдельный объект: за ним следят только
/// полоска, время и строка таймкода, а остальное окно перерисовывается лишь при смене песни, режима, связи.
final class Playhead: ObservableObject {
    struct Anchor: Equatable {
        var position = 0.0
        var date = Date.distantPast
    }
    /// Позиция в момент date; между обновлениями виды досчитывают сами (скорость 1)
    @Published private(set) var anchor = Anchor()
    @Published var drift: Int?
    @Published var timecode: String?

    func position(at date: Date) -> Double {
        anchor.position + date.timeIntervalSince(anchor.date)
    }

    /// Обновить, только если досчитанная позиция разошлась с настоящей (смена песни, перемотка, подстройка)
    func follow(_ position: Double, restart: Bool) {
        let now = Date()
        if restart || abs(self.position(at: now) - position) > 0.25 {
            anchor = Anchor(position: position, date: now)
        }
    }
}

/// Вывод на экран сцены
enum OutputState: Equatable {
    case off
    case live(display: String)
    case waitingForDisplay(display: String)
}

/// Сердце программы: MIDI → Director → VideoEngine, сеты, настройки, состояние для окна
final class Show: ObservableObject {
    static let shared = Show()

    @Published var settings: Settings {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }
    /// Что известно о файлах: путь → сведения
    @Published private(set) var media: [String: MediaInfo] = [:]
    @Published private(set) var nowPlaying = NowPlaying()
    let playhead = Playhead()
    /// Что вернуть на экране сцены при выходе — свой файл, пишется сразу
    var stage = StageState() {
        didSet { if stage != oldValue { Store.saveStage(stage) } }
    }
    @Published private(set) var logic = LogicStatus()
    @Published private(set) var outputState: OutputState = .off
    @Published private(set) var manualBlack = false
    @Published private(set) var manualLogo = false
    @Published private(set) var isManual = false
    /// Найденные в сети Mac + запомненный Logic Mac (для выбора в Settings)
    @Published private(set) var linkChoices: [LinkTarget] = []
    @Published private(set) var hasMIDISession = true
    /// Тестовая сетка на экране сцены (не сохраняется: после перезапуска — шоу, а не сетка)
    @Published var testPattern = false {
        didSet {
            if testPattern { engine.testPatternTitle = testPatternTitle }
            engine.testPattern = testPattern
        }
    }
    @Published private(set) var midiSessionName = ""

    let director = Director()
    let engine = VideoEngine()
    let midi = MIDIInput()
    let link = NetworkMIDILink()
    private(set) lazy var output = OutputController(engine: engine)
    private(set) lazy var preview = PreviewMirror(engine: engine)

    var timer: Timer?
    var ticks = 0
    var sleepAssertion: IOPMAssertionID = 0
    /// Когда пропала связь с Logic Mac (для баннера — не показывать короткие перебои)
    var linkDownSince: Date?
    var lastTitleState: OutputState?
    var everConnected = false

    /// Какой режим уже пробовали поставить на подключённый экран. Одна попытка на подключение:
    /// если экран принял режим чуть иначе (59.94 вместо 60 Гц), иначе ставили бы его по кругу — проектор мигал бы
    var modeAttempts: [String: DisplayModeRef] = [:]
    /// Пока открыто «Keep this resolution?» — сохранённый режим сам не ставим, иначе он перебьёт пробный
    var resolutionTrialKey: String?

    /// Что сейчас играет в Extras (для подсветки строки и Now Playing)
    @Published private(set) var extrasNow: (playlist: UUID, item: UUID)?
    var extrasItems: [PlaylistItem] = []
    var extrasPlaylist: UUID?

    private init() {
        settings = Store.loadSettings()
        stage = Store.loadStage()
        // Перенос из старого места (settings.json)
        if !settings.legacyOriginalModes.isEmpty || !settings.legacyPreviousWallpapers.isEmpty {
            stage.originalModes.merge(settings.legacyOriginalModes) { a, _ in a }
            stage.previousWallpapers.merge(settings.legacyPreviousWallpapers) { a, _ in a }
            settings.legacyOriginalModes = [:]
            settings.legacyPreviousWallpapers = [:]
        }
    }

    func start() {
        migrateLegacyFolder()
        assignMissingNotes()
        applyToEngine()
        engine.urlForCue = { [weak self] id in self?.activeItem(id)?.url }
        engine.startForCue = { [weak self] id in self?.activeItem(id)?.trimStart ?? 0 }
        director.onCueLearned = { [weak self] id, position in self?.learned(id, at: position) }
        engine.extras.onFinished = { [weak self] in
            self?.director.extrasFinished()
            self?.syncManualState()
        }
        director.onTimecodeGap = { gap in Log.info("Таймкод: пауза \(Int(gap * 1000)) мс") }
        midi.onEvents = { [weak self] events in
            guard let self else { return }
            for (event, host) in events {
                if case .sysex(let payload) = event {
                    let hex = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                    Log.info("SysEx: F0 \(hex) F7 → \(MTCSysex.parse(payload))")
                }
                self.director.handle(event, host: host)
            }
        }
        midi.start()
        link.log = { Log.info("Сеть MIDI: " + $0) }
        link.onChange = { [weak self] in self?.updateLinkChoices() }
        link.keepConnectedTo = settings.logicMac.map { NetworkMIDILink.Peer(name: $0.name, address: $0.address, ip: $0.ip) }
        link.start()
        preventDisplaySleep()

        output.onStageScreen = { [weak self] screen in self?.stageScreenFound(screen) }
        // Экран отключили — при следующем подключении режим ставим снова
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let present = Set(NSScreen.screens.map(self.stageKey))
            self.modeAttempts = self.modeAttempts.filter { present.contains($0.key) }
        }
        output.choice = outputChoice
        output.live = settings.live
        engine.logo.load(settings.logoPath.map(URL.init(fileURLWithPath:)))
        if settings.live { Log.info("Трансляция включается сразу (была включена при прошлом запуске)") }
        inspectMedia()
        rebuildCues()

        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Вывод и ручной режим

    func toggleLive() {
        settings.live.toggle()
        Log.info(settings.live ? "В эфир" : "Трансляция выключена")
    }

    func toggleBlackout() {
        director.manualBlack.toggle()
        Log.info("Затемнение: \(director.manualBlack ? "вкл" : "выкл")")
        syncManualState()
    }

    func toggleLogo() {
        director.stopManual()
        director.manualLogo.toggle()
        Log.info("Ручной логотип: \(director.manualLogo ? "вкл" : "выкл")")
        syncManualState()
    }

    func resumeSync() {
        director.resumeSync()
        Log.info("Resume Sync: снова по Logic")
        syncManualState()
    }

    /// Аварийный ручной запуск песни активного сета: до конца, потом логотип
    func playManually(_ item: SetlistItem) {
        guard let index = settings.active?.items.firstIndex(where: { $0.id == item.id }) else { return }
        director.playManually(index + 1, at: HostTime.now)
        Log.info("Ручной запуск: \(index + 1) \(item.displayName)")
        syncManualState()
    }

    func syncManualState() {
        if manualBlack != director.manualBlack { manualBlack = director.manualBlack }
        if manualLogo != director.manualLogo { manualLogo = director.manualLogo }
        if isManual != director.isManual { isManual = director.isManual }
    }

    func setScale(_ mode: ScaleMode) {
        settings.scale = mode
        Log.info("Масштаб: \(mode.title)")
    }

    // MARK: - Logic Mac

    func connectLogic(_ target: LinkTarget) {
        settings.logicMac = target
        let peer = NetworkMIDILink.Peer(name: target.name, address: target.address, ip: target.ip)
        link.keepConnectedTo = peer
        if link.connections.contains(where: { $0.address != target.address }) { link.disconnectAll() }
        link.connect(peer)
    }

    func disconnectLogic() {
        settings.logicMac = nil
        link.keepConnectedTo = nil
        link.disconnectAll()
    }

    func updateLinkChoices() {
        var list = link.peers.map { LinkTarget(name: $0.name, address: $0.address, ip: $0.ip) }
        if let saved = settings.logicMac {
            if let found = list.first(where: { $0.name == saved.name }) {
                // Запомнить свежий адрес и IP Logic Mac (IP пригодится, если поиск по имени перестанет работать)
                if found.address != saved.address {
                    settings.logicMac?.address = found.address
                    link.keepConnectedTo = NetworkMIDILink.Peer(name: found.name, address: found.address, ip: found.ip ?? saved.ip)
                }
                if let ip = found.ip, ip != saved.ip {
                    settings.logicMac?.ip = ip
                    link.keepConnectedTo?.ip = ip
                    Log.info("Logic Mac: запомнен IP \(ip)")
                }
            } else {
                list.append(saved)
            }
        }
        if list != linkChoices { linkChoices = list }
    }

    // MARK: - Внутреннее

    /// Старый формат (одна папка с номерами) → сет с тем же порядком и выученными метками
    func migrateLegacyFolder() {
        guard settings.setlists.isEmpty, let path = settings.legacyFolderPath else { return }
        let folder = URL(fileURLWithPath: path)
        let scan = Library.scanLegacyFolder(folder)
        let marks = settings.legacyMarkers[path] ?? [:]
        let items = scan.songs.map { SetlistItem(path: $0.url.path, marker: marks[String($0.number)]) }
        let name = folder.lastPathComponent
        let setlist = Setlist(name: name.isEmpty ? "Setlist" : name, items: items)
        settings.setlists = [setlist]
        settings.activeSetlist = setlist.id
        if settings.logoPath == nil { settings.logoPath = scan.logo?.path }
        let numbers = scan.songs.map(\.number)
        if !numbers.isEmpty, numbers != Array(1...numbers.count) {
            Log.info("Перенос: номера файлов с пропусками \(numbers) — ноты-метки теперь по позиции в списке, проверь ноты в Logic")
        }
        settings.legacyFolderPath = nil
        settings.legacyMarkers = [:]
        Log.info("Перенос: папка «\(name)» → сет из \(items.count) песен, логотип: \(scan.logo?.lastPathComponent ?? "нет")")
    }

    /// Проверить файлы, о которых ещё ничего не известно (и пропавшие — вдруг появились)
    func inspectMedia() {
        var paths = Set(settings.setlists.flatMap { $0.items.map(\.path) })
        paths.formUnion(settings.playlists.flatMap { $0.items.map(\.path) })
        if let logo = settings.logoPath { paths.insert(logo) }
        let todo = paths.filter { media[$0] == nil || media[$0]?.missing == true }
        guard !todo.isEmpty else { return }
        Task { @MainActor in
            for path in todo {
                let info = await Library.inspect(URL(fileURLWithPath: path))
                if media[path] != info {
                    if info.missing, media[path]?.missing != true { Log.info("Файл не найден: \(path)") }
                    if let error = info.error { Log.info("Файл \(path): \(error)") }
                    media[path] = info
                    rebuildCues()
                }
            }
        }
    }

    func rebuildCues() {
        let items = settings.active?.items ?? []
        var cues: [Int: CueInfo] = [:]
        for (i, item) in items.enumerated() {
            // Картинка вместо видео песни висит, пока не придёт другой сигнал
            let d = media[item.path].map { $0.playable && $0.isImage } == true ? .infinity : duration(item)
            guard let d else { continue }
            cues[i + 1] = CueInfo(id: i + 1, duration: d, start: item.marker)
        }
        if cues != director.cues { director.cues = cues }
        var map: [Int: Int] = [:]
        if let active = settings.active {
            for (i, item) in active.items.enumerated() { map[note(item, in: active)] = i + 1 }
        }
        if map != director.noteMap { director.noteMap = map }
    }

    func learned(_ id: Int, at position: Double) {
        guard let active = settings.activeSetlist, let item = activeItem(id) else { return }
        edit(active) { s in
            if let i = s.items.firstIndex(where: { $0.id == item.id }) { s.items[i].marker = position }
        }
        Log.info("Метка: песня \(id) «\(item.displayName)» начинается в \(Timecode(realSeconds: position, rate: director.clock.rate).text)")
    }

    func applyToEngine() {
        let d = settings.transition == .cut ? 0 : settings.transitionDuration
        engine.fadeOut = d
        engine.fadeIn = d
        engine.crossfade = settings.transition == .crossfade
        engine.scale = settings.scale
        engine.fit = settings.screenFit
        midi.onlyNetwork = settings.acceptOnlyLogic
        OutputView.hidePointer = settings.hidePointer
        director.fadeOut = d
        director.markerBaseNote = settings.markerBaseNote
        engine.extras.imageDuration = max(1, settings.extrasImageDuration)
        engine.extras.volume = Float(settings.extrasVolume)
        engine.extras.muted = !settings.live
        if engine.extras.audioDevice != settings.extrasAudioDevice { engine.extras.audioDevice = settings.extrasAudioDevice }
    }

    func settingsChanged(from old: Settings) {
        // Сменили ноту первой песни — сдвинуть все ноты
        if settings.markerBaseNote != old.markerBaseNote {
            let delta = settings.markerBaseNote - old.markerBaseNote
            for s in settings.setlists.indices {
                for i in settings.setlists[s].items.indices {
                    if let n = settings.setlists[s].items[i].note { settings.setlists[s].items[i].note = min(127, max(0, n + delta)) }
                }
            }
        }
        // Правки подгонки сразу сохраняются в выбранный пресет площадки
        if settings.screenFit != old.screenFit, let id = settings.venuePreset,
           let i = settings.venuePresets.firstIndex(where: { $0.id == id }), settings.venuePresets[i].fit != settings.screenFit {
            settings.venuePresets[i].fit = settings.screenFit
        }
        Store.scheduleSave(settings)
        applyToEngine()
        output.choice = outputChoice
        output.live = settings.live
        if settings.live, settings.restartScreen != old.restartScreen || settings.restartImagePath != old.restartImagePath || !old.live,
           let screen = stageScreen {
            setRestartWallpaper(on: screen)
        }
        if settings.logoPath != old.logoPath {
            engine.logo.load(settings.logoPath.map(URL.init(fileURLWithPath:)))
            inspectMedia()
        }
        if settings.setlists != old.setlists || settings.activeSetlist != old.activeSetlist {
            inspectMedia()
            rebuildCues()
        }
    }

    func tick() {
        let now = HostTime.now
        let out = director.output(at: now)
        engine.update(out, next: director.nextCue(after: out), now: now)
        engine.extras.tick(now: now)
        // Extras ушли с экрана (песня из Logic, Logo, Resume Sync) — остановить вместе со звуком
        if out != .extras, engine.extras.isPlaying, !engine.extrasVisible {
            engine.extras.stop()
            extrasPlaylist = nil
        }
        preview.sync()
        if settings.hideDock { keepPointerOffStage() }

        ticks += 1
        if ticks % 6 == 0 { updateStatus(out, now: now) }
        if ticks % 60 == 0 { Store.heartbeat() }
        // Пропавшие файлы (отключённый диск) — проверить, не вернулись ли
        if ticks % 300 == 0, media.values.contains(where: \.missing) { inspectMedia() }
        // Качество сети: раз в 10 с, пока идёт таймкод
        if ticks % 600 == 0 {
            let s = director.takeClockStats()
            if s.quarterFrames > 0 {
                let perSec = Double(s.quarterFrames) / 10
                let expected = director.clock.rate.fps * 4
                Log.info(String(format: "Таймкод: %.0f из %.0f сообщ./с (%.0f%%), макс. пауза %d мс, отброшено скачков %d, принято перемоток %d",
                                perSec, expected, min(100, perSec / expected * 100), Int(s.maxGap * 1000), s.rejectedJumps, s.acceptedJumps))
            }
        }
        if ticks % 300 == 0, case .song(let id, let position, let locked) = out {
            let drift = engine.activeSlot?.drift.map { "\(Int($0 * 1000)) мс" } ?? "—"
            Log.info("Песня \(id): \(String(format: "%.2f", position)) с, \(locked ? "по таймкоду" : "сама"), расхождение \(drift)")
        }
    }

    func updateStatus(_ out: ShowOutput, now: Double) {
        syncManualState()
        updateNowPlaying(out)
        updateLogic(now: now)

        let state: OutputState
        if !settings.live {
            state = .off
        } else if let target = output.currentTarget {
            state = .live(display: target)
        } else {
            state = .waitingForDisplay(display: expectedDisplayName)
        }
        if state != outputState { outputState = state }
        // Подпись сетки (перебор экранов) — только когда сетка включена, раз в секунду
        if engine.testPattern, ticks % 60 == 0 || state != lastTitleState {
            engine.testPatternTitle = testPatternTitle
            lastTitleState = state
        }
    }

    func updateNowPlaying(_ out: ShowOutput) {
        var n = NowPlaying()
        var position: Double?
        var playPosition: Double?
        var drift: Int?
        switch out {
        case .black:
            n.mode = .black
        case .logo:
            n.mode = .logo
        case .extras:
            let x = engine.extras
            n.mode = .extras
            n.number = x.index + 1
            if extrasItems.indices.contains(x.index) {
                n.itemID = extrasItems[x.index].id
                n.title = extrasItems[x.index].displayName
            }
            n.isImage = x.currentSlot.isImage
            position = x.position
            n.duration = x.duration
            let name = playlist(extrasPlaylist)?.name ?? "Extras"
            switch x.mode {
            case .single: n.extrasSource = name + " · single file"
            case .playlist(let r): n.extrasSource = name + (r == .off ? "" : " · Repeat \(r.title)")
            }
        case .song(let id, let position, let locked):
            n.mode = director.manualPlay != nil ? .manual : locked ? .locked : .free
            n.number = id
            playPosition = position
            if let item = activeItem(id) {
                n.itemID = item.id
                n.title = item.displayName
                n.duration = duration(item) ?? 0
            }
            drift = engine.activeSlot?.drift.map { Int(($0 * 1000).rounded()) }
        }
        if out != .extras, let next = director.nextCue(after: out), let item = activeItem(next) {
            n.next = String(format: "%02d", next) + " " + item.displayName
                + " · marker " + Self.noteName(note(item, in: settings.active))
        }
        let restart = n.itemID != nowPlaying.itemID || n.mode != nowPlaying.mode
        if n != nowPlaying { nowPlaying = n }
        playhead.follow(position ?? playPosition ?? 0, restart: restart)
        // Расхождение — 2 раза в секунду, чаще читать незачем
        if ticks % 30 == 0, playhead.drift != drift { playhead.drift = drift }
        let playing = out == .extras ? extrasPlaylist.flatMap { p in n.itemID.map { (p, $0) } } : nil
        if playing?.0 != extrasNow?.playlist || playing?.1 != extrasNow?.item { extrasNow = playing }
    }

    func updateLogic(now: Double) {
        var s = LogicStatus()
        // Снимок, а не живой опрос: запросы к MIDI-серверу 10 раз в секунду могли подвесить главный поток
        let snap = link.snapshot
        let session = snap.hasSession
        if session != hasMIDISession { hasMIDISession = session }
        if snap.sessionName != midiSessionName { midiSessionName = snap.sessionName }

        let connections = snap.connections
        let age = director.lastMessageHost.map { now - $0 }
        let midiFlowing = (age ?? 99) < 2
        // Подключение записано в сеансе, даже когда тот Mac выключен — поэтому ещё и «виден ли он в сети сейчас»
        let visible = connections.contains { link.isVisible($0.name) }
        let connected = midiFlowing || (!connections.isEmpty && visible)
        s.macName = connections.first?.name ?? settings.logicMac?.name
        s.visible = s.macName.map(link.isVisible) ?? false

        let clock = director.clock
        var timecode: String?
        if let pos = clock.position(at: now) {
            s.mtcRunning = true
            s.fps = "\(clock.rate.label) fps"
            timecode = Timecode(realSeconds: pos, rate: clock.rate).text
        } else if let pos = director.lastKnownPosition {
            timecode = Timecode(realSeconds: pos, rate: clock.rate).text
        }
        if playhead.timecode != timecode { playhead.timecode = timecode }

        if connected {
            everConnected = true
            linkDownSince = nil
            s.state = .connected
        } else if !session {
            s.state = .noSession
        } else {
            let since = linkDownSince ?? Date()
            linkDownSince = since
            // Короткие перебои и первые секунды после запуска — не тревога
            s.state = everConnected && Date().timeIntervalSince(since) > 3 ? .lost : .waiting
        }
        if s != logic { logic = s }
    }

    /// Как называется экран сцены, пока его нет
    var expectedDisplayName: String {
        switch settings.display {
        case .specific(let ref): return ref.name
        case .firstExternal: return "Stage display"
        case .window: return "Test window"
        }
    }

    /// Не гасить экран и не засыпать, пока программа работает
    func preventDisplaySleep() {
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Live Video Sync: show output" as CFString, &sleepAssertion)
        Log.info(result == kIOReturnSuccess ? "Сон экрана запрещён" : "Не удалось запретить сон экрана (\(result))")
    }

    /// 3:42
    static func minutes(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// 02:14.6
    static func clock(_ seconds: Double) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }

    /// Имена нот как в Logic: 36 = C1, 60 = C3
    static func noteName(_ n: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        guard (0...127).contains(n) else { return "—" }
        return "\(names[n % 12])\(n / 12 - 2)"
    }
}
