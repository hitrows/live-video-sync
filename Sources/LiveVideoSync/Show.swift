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
    var position = 0.0
    var duration = 0.0
    /// Когда позиция была position — между обновлениями полоска досчитывает сама (плавно)
    var positionDate = Date.distantPast
    var drift: Int?
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
    var timecode: String?
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
            var parts = ["Source: \(macName ?? "connected")", "connected"]
            if let timecode { parts.append(timecode) }
            if let fps { parts.append(fps) }
            return parts.joined(separator: " · ")
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
        didSet { engine.testPattern = testPattern }
    }
    @Published private(set) var midiSessionName = ""

    let director = Director()
    let engine = VideoEngine()
    let midi = MIDIInput()
    let link = NetworkMIDILink()
    private(set) lazy var output = OutputController(engine: engine)
    private(set) lazy var preview = PreviewMirror(engine: engine)

    private var timer: Timer?
    private var ticks = 0
    private var sleepAssertion: IOPMAssertionID = 0
    /// Когда пропала связь с Logic Mac (для баннера — не показывать короткие перебои)
    private var linkDownSince: Date?
    private var everConnected = false

    private init() {
        settings = Store.loadSettings()
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

    // MARK: - Экран сцены: разрешение и обои на время перезапуска

    /// Экран сцены, если подключён (для Settings → Output)
    var stageScreen: NSScreen? {
        settings.testWindow ? nil : OutputController.targetScreen(for: settings.display)
    }

    /// Куда вывод: экран сцены или тестовое окно
    private var outputChoice: DisplayChoice { settings.testWindow ? .window : settings.display }

    /// «A200 HDMI · 1280 × 800 px» — экран и размер вывода в пикселях
    private var testPatternTitle: String {
        let size = engine.rootLayer.bounds.size
        let scale = settings.testWindow ? (NSScreen.main?.backingScaleFactor ?? 1) : (stageScreen?.backingScaleFactor ?? 1)
        let name: String
        switch outputState {
        case .live(let display): name = settings.testWindow ? "Test window" : display
        default: name = settings.testWindow ? "Test window" : expectedDisplayName
        }
        engine.pixelScale = scale
        return "\(name) · \(Int(size.width * scale)) × \(Int(size.height * scale)) px"
    }

    func toggleTestWindow() {
        settings.testWindow.toggle()
        Log.info(settings.testWindow ? "Вывод в тестовое окно" : "Вывод на экран сцены")
    }

    // MARK: - Ноты-метки

    /// Нота-метка песни
    func note(_ item: SetlistItem, in setlist: Setlist? = nil) -> Int {
        if let n = item.note { return n }
        let list = setlist ?? settings.setlists.first { $0.items.contains { $0.id == item.id } }
        let index = list?.items.firstIndex { $0.id == item.id } ?? 0
        return settings.markerBaseNote + index
    }

    /// Следующая свободная нота в сете (после самой высокой)
    private func nextFreeNote(in setlist: Setlist) -> Int {
        let used = setlist.items.compactMap(\.note)
        return min(127, (used.max().map { $0 + 1 }) ?? settings.markerBaseNote)
    }

    /// Песням без ноты — ноты по порядку (старые настройки: нота = место в списке)
    private func assignMissingNotes() {
        for s in settings.setlists.indices where settings.setlists[s].items.contains(where: { $0.note == nil }) {
            for i in settings.setlists[s].items.indices where settings.setlists[s].items[i].note == nil {
                settings.setlists[s].items[i].note = settings.markerBaseNote + i
            }
        }
    }

    /// Сменить ноту песни; если она занята другой песней сета — поменяться с ней
    func setNote(_ note: Int, for itemID: UUID, in setlistID: UUID) {
        edit(setlistID) { s in
            guard let i = s.items.firstIndex(where: { $0.id == itemID }) else { return }
            let old = s.items[i].note
            if let j = s.items.firstIndex(where: { $0.note == note && $0.id != itemID }) { s.items[j].note = old }
            s.items[i].note = note
        }
        Log.info("Нота-метка: \(Self.noteName(note))")
    }

    func stageKey(_ screen: NSScreen) -> String {
        DisplayModes.displayKey(OutputController.ref(for: screen))
    }

    private func stageScreenFound(_ screen: NSScreen) {
        let key = stageKey(screen)
        let id = OutputController.displayID(screen)
        if let wanted = settings.resolutions[key] {
            if settings.originalModes[key] == nil, let current = DisplayModes.current(id), current != wanted {
                settings.originalModes[key] = current
            }
            DisplayModes.set(wanted, on: id)
        }
        if settings.live { setRestartWallpaper(on: screen) }
    }

    /// Пробный режим из Settings: ставится сразу, сохраняется только после Keep
    func tryResolution(_ wanted: DisplayModeRef?, on screen: NSScreen) -> DisplayModeRef? {
        let key = stageKey(screen)
        let id = OutputController.displayID(screen)
        let before = DisplayModes.current(id)
        if let wanted {
            if settings.originalModes[key] == nil, let before { settings.originalModes[key] = before }
            DisplayModes.set(wanted, on: id)
        } else if let original = settings.originalModes[key] {
            DisplayModes.set(original, on: id)
        }
        return before
    }

    func keepResolution(_ wanted: DisplayModeRef?, on screen: NSScreen) {
        let key = stageKey(screen)
        settings.resolutions[key] = wanted
        if wanted == nil { settings.originalModes[key] = nil }
        Log.info("Разрешение экрана сцены: \(wanted?.title ?? "Default") — сохранено")
    }

    func revertResolution(to mode: DisplayModeRef?, on screen: NSScreen) {
        guard let mode else { return }
        DisplayModes.set(mode, on: OutputController.displayID(screen))
        Log.info("Разрешение экрана сцены возвращено: \(mode.title)")
    }

    /// Картинка (или чёрное) обоями экрана сцены: если программа упадёт, пока она перезапускается — видно это, а не рабочий стол
    private func setRestartWallpaper(on screen: NSScreen) {
        guard let url = restartImageURL else { return }
        let key = stageKey(screen)
        let current = NSWorkspace.shared.desktopImageURL(for: screen)
        guard current?.standardizedFileURL != url.standardizedFileURL else { return }
        if settings.previousWallpapers[key] == nil, let current { settings.previousWallpapers[key] = current.path }
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true,
                .fillColor: NSColor.black,
            ])
            Log.info("Обои экрана сцены: \(url.lastPathComponent)")
        } catch {
            Log.info("Не удалось поставить обои экрана сцены: \(error.localizedDescription)")
        }
    }

    private var restartImageURL: URL? {
        if settings.restartScreen == .image, let path = settings.restartImagePath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return Store.blackImageURL
    }

    func chooseRestartImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use Image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.restartImagePath = url.path
        settings.restartScreen = .image
        if let screen = stageScreen, settings.live { setRestartWallpaper(on: screen) }
    }

    /// Штатный выход: вернуть прежние разрешение и обои экрана сцены
    func restoreStageScreen() {
        for screen in NSScreen.screens {
            let key = stageKey(screen)
            if let original = settings.originalModes[key] {
                DisplayModes.set(original, on: OutputController.displayID(screen))
                settings.originalModes[key] = nil
            }
            if let path = settings.previousWallpapers[key] {
                try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])
                settings.previousWallpapers[key] = nil
                Log.info("Обои экрана «\(screen.localizedName)» возвращены")
            }
        }
    }

    /// Dock переезжает на экран, где курсор упёрся в нижний край. Спрятать Dock только на одном экране macOS не даёт,
    /// поэтому во время вывода курсор на экран сцены не пускаем — и Dock туда не попадёт. Основной экран не трогаем.
    private func keepPointerOffStage() {
        guard settings.live, !settings.testWindow, let stage = output.currentScreen else { return }
        let mouse = NSEvent.mouseLocation
        guard stage.frame.contains(mouse),
              let other = NSScreen.screens.filter({ $0 != stage }).min(by: { distance($0.frame, mouse) < distance($1.frame, mouse) }),
              let primary = NSScreen.screens.first else { return }
        // Ближайшая точка соседнего экрана, на 2 pt внутрь
        let f = other.frame.insetBy(dx: 2, dy: 2)
        let p = CGPoint(x: min(max(mouse.x, f.minX), f.maxX), y: min(max(mouse.y, f.minY), f.maxY))
        CGWarpMouseCursorPosition(CGPoint(x: p.x, y: primary.frame.height - p.y))
    }

    private func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    // MARK: - Screen Fit

    var venuePresetName: String? {
        settings.venuePresets.first { $0.id == settings.venuePreset }?.name
    }

    func choosePreset(_ id: UUID) {
        guard let preset = settings.venuePresets.first(where: { $0.id == id }) else { return }
        settings.venuePreset = id
        settings.screenFit = preset.fit
        Log.info("Screen Fit: пресет «\(preset.name)»")
    }

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let preset = VenuePreset(name: trimmed, fit: settings.screenFit)
        settings.venuePresets.append(preset)
        settings.venuePreset = preset.id
        Log.info("Screen Fit: сохранён пресет «\(trimmed)»")
    }

    func renamePreset(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = settings.venuePresets.firstIndex(where: { $0.id == id }) else { return }
        settings.venuePresets[i].name = trimmed
    }

    func deletePreset(_ id: UUID) {
        settings.venuePresets.removeAll { $0.id == id }
        if settings.venuePreset == id { settings.venuePreset = nil }
    }

    // MARK: - Extras

    /// Что сейчас играет в Extras (для подсветки строки и Now Playing)
    @Published private(set) var extrasNow: (playlist: UUID, item: UUID)?
    private var extrasItems: [PlaylistItem] = []
    private var extrasPlaylist: UUID?

    /// ▶ Play в шапке плейлиста — по порядку, с повтором плейлиста
    func playPlaylist(_ id: UUID, from itemID: UUID? = nil) {
        guard let playlist = playlist(id) else { return }
        let items = playlist.items.filter { media[$0.path]?.playable ?? false }
        guard !items.isEmpty else { return }
        let start = itemID.flatMap { i in items.firstIndex { $0.id == i } } ?? 0
        startExtras(items, playlist: id, from: start, mode: .playlist(playlist.repeatMode))
        Log.info("Extras: плейлист «\(playlist.name)» с \(start + 1)-го, повтор \(playlist.repeatMode.title)")
    }

    /// ▶ у строки — один файл: видео до конца, потом логотип; картинка — бесконечно
    func playExtra(_ item: PlaylistItem, in playlistID: UUID) {
        guard media[item.path]?.playable ?? false else { return }
        startExtras([item], playlist: playlistID, from: 0, mode: .single)
    }

    private func startExtras(_ items: [PlaylistItem], playlist: UUID, from index: Int, mode: ExtrasPlayer.Mode) {
        let entries = items.map { ExtrasPlayer.Entry(url: $0.url, isImage: media[$0.path]?.isImage ?? false) }
        extrasItems = items
        extrasPlaylist = playlist
        let now = HostTime.now
        engine.extras.play(entries, from: index, mode: mode, now: now)
        director.startExtras(at: now)
        syncManualState()
    }

    func playlist(_ id: UUID?) -> Playlist? {
        settings.playlists.first { $0.id == id }
    }

    private func editPlaylist(_ id: UUID, _ body: (inout Playlist) -> Void) {
        guard let i = settings.playlists.firstIndex(where: { $0.id == id }) else { return }
        body(&settings.playlists[i])
    }

    @discardableResult
    func newPlaylist() -> UUID {
        var title = "Untitled Playlist"
        var n = 2
        while settings.playlists.contains(where: { $0.name == title }) {
            title = "Untitled Playlist \(n)"
            n += 1
        }
        let playlist = Playlist(name: title)
        settings.playlists.append(playlist)
        Log.info("Новый плейлист Extras: \(title)")
        return playlist.id
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        editPlaylist(id) { $0.name = trimmed }
    }

    func deletePlaylist(_ id: UUID) {
        if extrasPlaylist == id { director.stopManual(); engine.extras.stop() }
        settings.playlists.removeAll { $0.id == id }
    }

    func setRepeat(_ mode: RepeatMode, for id: UUID) {
        editPlaylist(id) { $0.repeatMode = mode }
    }

    func addFiles(_ urls: [URL], toPlaylist id: UUID, at index: Int? = nil) {
        let files = urls.flatMap(expandFolder).filter(Library.isMedia)
        guard !files.isEmpty else { return }
        editPlaylist(id) { p in
            let at = min(max(0, index ?? p.items.count), p.items.count)
            p.items.insert(contentsOf: files.map { PlaylistItem(path: $0.path) }, at: at)
        }
        inspectMedia()
    }

    func removePlaylistItems(_ ids: Set<UUID>, from id: UUID) {
        editPlaylist(id) { $0.items.removeAll { ids.contains($0.id) } }
    }

    func movePlaylistItems(in id: UUID, from offsets: IndexSet, to destination: Int) {
        editPlaylist(id) { $0.items.move(fromOffsets: offsets, toOffset: destination) }
    }

    func renamePlaylistItem(_ itemID: UUID, in id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        editPlaylist(id) { p in
            guard let i = p.items.firstIndex(where: { $0.id == itemID }) else { return }
            p.items[i].title = trimmed.isEmpty ? nil : trimmed
        }
    }

    func replacePlaylistFile(_ itemID: UUID, in id: UUID) {
        guard let item = playlist(id)?.items.first(where: { $0.id == itemID }) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image]
        panel.prompt = "Choose"
        panel.directoryURL = item.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editPlaylist(id) { p in
            guard let i = p.items.firstIndex(where: { $0.id == itemID }) else { return }
            p.items[i].path = url.path
        }
        inspectMedia()
    }

    /// Аварийный ручной запуск песни активного сета: до конца, потом логотип
    func playManually(_ item: SetlistItem) {
        guard let index = settings.active?.items.firstIndex(where: { $0.id == item.id }) else { return }
        director.playManually(index + 1, at: HostTime.now)
        Log.info("Ручной запуск: \(index + 1) \(item.displayName)")
        syncManualState()
    }

    private func syncManualState() {
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

    private func updateLinkChoices() {
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

    // MARK: - Сеты

    func setlist(_ id: UUID?) -> Setlist? {
        settings.setlists.first { $0.id == id }
    }

    /// Песня активного сета по номеру (1…)
    func activeItem(_ number: Int) -> SetlistItem? {
        guard let items = settings.active?.items, number >= 1, number <= items.count else { return nil }
        return items[number - 1]
    }

    private func edit(_ id: UUID, _ body: (inout Setlist) -> Void) {
        guard let i = settings.setlists.firstIndex(where: { $0.id == id }) else { return }
        body(&settings.setlists[i])
    }

    @discardableResult
    func newSetlist(name: String? = nil) -> UUID {
        let base = name ?? "Untitled Setlist"
        var title = base
        var n = 2
        while settings.setlists.contains(where: { $0.name == title }) {
            title = "\(base) \(n)"
            n += 1
        }
        let setlist = Setlist(name: title)
        settings.setlists.append(setlist)
        // Первый сет сразу активный — играть больше нечему
        if settings.activeSetlist == nil { settings.activeSetlist = setlist.id }
        Log.info("Новый сет: \(title)")
        return setlist.id
    }

    func renameSetlist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        edit(id) { $0.name = trimmed }
    }

    func deleteSetlist(_ id: UUID) {
        guard let s = setlist(id) else { return }
        settings.setlists.removeAll { $0.id == id }
        if settings.activeSetlist == id { settings.activeSetlist = nil }
        Log.info("Сет удалён: \(s.name)")
    }

    func makeActive(_ id: UUID) {
        guard let s = setlist(id) else { return }
        settings.activeSetlist = id
        Log.info("Активный сет: \(s.name)")
    }

    /// Добавить файлы в сет (перетаскивание или Add Files…); index — куда вставить
    func addFiles(_ urls: [URL], to id: UUID, at index: Int? = nil) {
        let files = urls.flatMap(expandFolder).filter(Library.isMedia)
        guard !files.isEmpty else { return }
        guard let current = setlist(id) else { return }
        var next = nextFreeNote(in: current)
        let items: [SetlistItem] = files.map { url in
            var item = SetlistItem(path: url.path)
            item.note = next
            next = min(127, next + 1)
            return item
        }
        edit(id) { s in
            let at = min(max(0, index ?? s.items.count), s.items.count)
            s.items.insert(contentsOf: items, at: at)
        }
        inspectMedia()
        Log.info("В сет добавлено файлов: \(files.count)")
    }

    /// Папку — её видео и картинки по имени
    private func expandFolder(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [url] }
        return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func removeItems(_ ids: Set<UUID>, from setlistID: UUID) {
        edit(setlistID) { $0.items.removeAll { ids.contains($0.id) } }
    }

    func moveItems(in setlistID: UUID, from offsets: IndexSet, to destination: Int) {
        edit(setlistID) { $0.items.move(fromOffsets: offsets, toOffset: destination) }
    }

    /// Move to Position: песня встаёт на позицию (1…), остальные сдвигаются
    func moveItem(_ itemID: UUID, in setlistID: UUID, toPosition position: Int) {
        edit(setlistID) { s in
            guard let from = s.items.firstIndex(where: { $0.id == itemID }) else { return }
            let item = s.items.remove(at: from)
            s.items.insert(item, at: min(max(0, position - 1), s.items.count))
        }
    }

    func renameItem(_ itemID: UUID, in setlistID: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        edit(setlistID) { s in
            guard let i = s.items.firstIndex(where: { $0.id == itemID }) else { return }
            s.items[i].title = trimmed.isEmpty ? nil : trimmed
        }
    }

    func setTrim(_ itemID: UUID, in setlistID: UUID, start: Double, end: Double?) {
        edit(setlistID) { s in
            guard let i = s.items.firstIndex(where: { $0.id == itemID }) else { return }
            s.items[i].trimStart = max(0, start)
            s.items[i].trimEnd = end
        }
    }

    func resetMarker(_ itemID: UUID, in setlistID: UUID) {
        edit(setlistID) { s in
            guard let i = s.items.firstIndex(where: { $0.id == itemID }) else { return }
            s.items[i].marker = nil
        }
        Log.info("Метка сброшена")
    }

    func resetMarkers(in setlistID: UUID) {
        edit(setlistID) { s in
            for i in s.items.indices { s.items[i].marker = nil }
        }
        Log.info("Метки сета сброшены")
    }

    /// Replace File… и Locate… — выбрать другой файл для песни, метка и имя остаются
    func replaceFile(_ itemID: UUID, in setlistID: UUID) {
        guard let item = setlist(setlistID)?.items.first(where: { $0.id == itemID }) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image]
        panel.prompt = "Choose"
        panel.message = "Choose the file for “\(item.displayName)”"
        panel.directoryURL = item.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        edit(setlistID) { s in
            guard let i = s.items.firstIndex(where: { $0.id == itemID }) else { return }
            // Имя в списке сохраняем — его видит музыкант, а не имя файла
            if s.items[i].title == nil { s.items[i].title = item.displayName }
            s.items[i].path = url.path
            s.items[i].trimStart = 0
            s.items[i].trimEnd = nil
        }
        inspectMedia()
        Log.info("Файл песни заменён: \(url.lastPathComponent)")
    }

    func showInFinder(_ item: SetlistItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func info(_ item: SetlistItem) -> MediaInfo? { media[item.path] }

    /// Длительность песни с учётом обрезки
    func duration(_ item: SetlistItem) -> Double? {
        guard let info = media[item.path], info.playable, !info.isImage else { return nil }
        let end = min(item.trimEnd ?? info.duration, info.duration)
        return max(0.1, end - item.trimStart)
    }

    func totalDuration(_ setlist: Setlist) -> Double {
        setlist.items.compactMap(duration).reduce(0, +)
    }

    func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.prompt = "Use as Logo"
        if let path = settings.logoPath { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url { settings.logoPath = url.path }
    }

    // MARK: - Внутреннее

    /// Старый формат (одна папка с номерами) → сет с тем же порядком и выученными метками
    private func migrateLegacyFolder() {
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
    private func inspectMedia() {
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

    private func rebuildCues() {
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

    private func learned(_ id: Int, at position: Double) {
        guard let active = settings.activeSetlist, let item = activeItem(id) else { return }
        edit(active) { s in
            if let i = s.items.firstIndex(where: { $0.id == item.id }) { s.items[i].marker = position }
        }
        Log.info("Метка: песня \(id) «\(item.displayName)» начинается в \(Timecode(realSeconds: position, rate: director.clock.rate).text)")
    }

    private func applyToEngine() {
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
        if engine.extras.audioDevice != settings.extrasAudioDevice { engine.extras.audioDevice = settings.extrasAudioDevice }
    }

    private func settingsChanged(from old: Settings) {
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
        Store.save(settings)
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

    private func tick() {
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

    private func updateStatus(_ out: ShowOutput, now: Double) {
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
        engine.testPatternTitle = testPatternTitle
    }

    private func updateNowPlaying(_ out: ShowOutput) {
        var n = NowPlaying()
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
            n.position = x.position
            n.duration = x.duration
            let name = playlist(extrasPlaylist)?.name ?? "Extras"
            switch x.mode {
            case .single: n.extrasSource = name + " · single file"
            case .playlist(let r): n.extrasSource = name + (r == .off ? "" : " · Repeat \(r.title)")
            }
        case .song(let id, let position, let locked):
            n.mode = director.manualPlay != nil ? .manual : locked ? .locked : .free
            n.number = id
            n.position = position
            if let item = activeItem(id) {
                n.itemID = item.id
                n.title = item.displayName
                n.duration = duration(item) ?? 0
            }
            n.drift = engine.activeSlot?.drift.map { Int(($0 * 1000).rounded()) }
        }
        if out != .extras, let next = director.nextCue(after: out), let item = activeItem(next) {
            n.next = String(format: "%02d", next) + " " + item.displayName
                + " · marker " + Self.noteName(note(item, in: settings.active))
        }
        n.positionDate = Date()
        // Сравниваем без времени снимка — иначе обновлялось бы каждый раз
        var cmp = nowPlaying
        cmp.positionDate = n.positionDate
        if n != cmp || abs(n.position - nowPlaying.position) > 0.5 { nowPlaying = n }
        let playing = out == .extras ? extrasPlaylist.flatMap { p in n.itemID.map { (p, $0) } } : nil
        if playing?.0 != extrasNow?.playlist || playing?.1 != extrasNow?.item { extrasNow = playing }
    }

    private func updateLogic(now: Double) {
        var s = LogicStatus()
        let session = link.hasSession
        if session != hasMIDISession { hasMIDISession = session }
        let name = link.sessionName
        if name != midiSessionName { midiSessionName = name }

        let connections = link.connections
        let age = director.lastMessageHost.map { now - $0 }
        let midiFlowing = (age ?? 99) < 2
        // Подключение записано в сеансе, даже когда тот Mac выключен — поэтому ещё и «виден ли он в сети сейчас»
        let visible = connections.contains { link.isVisible($0.name) }
        let connected = midiFlowing || (!connections.isEmpty && visible)
        s.macName = connections.first?.name ?? settings.logicMac?.name
        s.visible = s.macName.map(link.isVisible) ?? false

        let clock = director.clock
        if let pos = clock.position(at: now) {
            s.mtcRunning = true
            s.timecode = Timecode(realSeconds: pos, rate: clock.rate).text
            s.fps = "\(clock.rate.label) fps"
        } else if let pos = director.lastKnownPosition {
            s.timecode = Timecode(realSeconds: pos, rate: clock.rate).text
        }

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
    private func preventDisplaySleep() {
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
