import AppKit
import Foundation

/// Экран для трансляции
struct DisplayRef: Codable, Equatable, Hashable {
    var name: String
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32
}

/// Масштаб видео на экране — пропорции всегда сохраняются, видео не растягивается
enum ScaleMode: String, Codable, CaseIterable {
    /// Целиком, при разных пропорциях — чёрные полосы
    case fit
    /// Заполнить экран, лишнее обрезается
    case fill
    /// По высоте экрана: лево/право обрезаются или полосы по бокам
    case fitHeight
    /// По ширине экрана: верх/низ обрезаются или полосы сверху и снизу
    case fitWidth

    var title: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .fitHeight: return "Fit height"
        case .fitWidth: return "Fit width"
        }
    }
}

enum DisplayChoice: Codable, Equatable, Hashable {
    /// Первый внешний экран (не встроенный и не основной)
    case firstExternal
    case specific(DisplayRef)
    /// Обычное окно — для проверки без второго экрана
    case window
}

/// Mac с Logic для сетевого MIDI
struct LinkTarget: Codable, Equatable, Hashable {
    var name: String
    /// «хост.local:порт»
    var address: String
    /// «IP:порт» — запасной адрес
    var ip: String?
}

/// Песня сет-листа: файл где угодно на диске. Номер и нота-метка = позиция в списке.
struct SetlistItem: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    /// Отображаемое имя (файл не переименовывается); nil — по имени файла
    var title: String?
    /// Обрезка (Trim): видео идёт с trimStart и кончается в trimEnd; файл не меняется
    var trimStart: Double = 0
    var trimEnd: Double?
    /// Нота-метка песни (любая; nil — ещё не назначена, назначит программа)
    var note: Int?
    /// Начало песни в проекте Logic (секунды MTC) — выучено по ноте-метке.
    /// Хранится у песни: при перестановке песни её место в проекте Logic не меняется.
    var marker: Double?

    init(path: String, title: String? = nil, marker: Double? = nil) {
        self.path = path
        self.title = title
        self.marker = marker
    }

    var url: URL { URL(fileURLWithPath: path) }

    /// «03_Song.mp4» → «Song»
    var displayName: String {
        if let title, !title.isEmpty { return title }
        let base = url.deletingPathExtension().lastPathComponent
        let stripped = base.replacingOccurrences(of: #"^\d+[\s_.\-]*"#, with: "", options: .regularExpression)
        return stripped.isEmpty ? base : stripped
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try c.decode(String.self, forKey: .path)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        marker = try c.decodeIfPresent(Double.self, forKey: .marker)
        note = try c.decodeIfPresent(Int.self, forKey: .note)
    }
}

struct Setlist: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var items: [SetlistItem] = []

    init(name: String, items: [SetlistItem] = []) {
        self.name = name
        self.items = items
    }
}

/// Файл плейлиста Extras
struct PlaylistItem: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var title: String?

    init(path: String) { self.path = path }

    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String {
        if let title, !title.isEmpty { return title }
        return url.lastPathComponent
    }
}

/// Повтор как в Apple Music
enum RepeatMode: String, Codable, CaseIterable {
    case off, all, one

    var title: String {
        switch self {
        case .off: return "Off"
        case .all: return "All"
        case .one: return "One"
        }
    }
}

/// Плейлист Extras — общий для всех сетов
struct Playlist: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var items: [PlaylistItem] = []
    var repeatMode: RepeatMode = .off

    init(name: String) { self.name = name }
}

/// Переход между песнями и логотипом
enum Transition: String, Codable, CaseIterable {
    /// Через чёрное
    case fade
    case crossfade
    case cut

    var title: String {
        switch self {
        case .fade: return "Fade"
        case .crossfade: return "Crossfade"
        case .cut: return "Cut"
        }
    }
}

/// Что на экране сцены, пока программа перезапускается после сбоя (обои рабочего стола)
enum RestartScreen: String, Codable, CaseIterable {
    case image, black
}

struct Settings: Codable, Equatable {
    var setlists: [Setlist] = []
    /// Сет, который играет по Logic
    var activeSetlist: UUID?
    var logoPath: String?
    var display: DisplayChoice = .firstExternal
    /// Вывод в окно на этом Mac вместо экрана сцены (кнопка на панели инструментов)
    var testWindow = false
    var transition: Transition = .fade
    /// Fade out и fade in, с
    var transitionDuration: Double = 0.7
    var scale: ScaleMode = .fit
    var markerBaseNote = 36
    /// Была ли трансляция включена — после перезапуска включаем снова
    var live = false
    /// С кем держать сетевой MIDI (плеер сам переподключается)
    var logicMac: LinkTarget?
    var hideDock = true
    var hidePointer = true
    var restartScreen: RestartScreen = .image
    var restartImagePath: String?
    var playlists: [Playlist] = []
    /// Одна длительность на все картинки Extras, с
    var extrasImageDuration: Double = 10
    /// Выход звука Extras (UID устройства CoreAudio); nil — системный
    var extrasAudioDevice: String?
    var extrasVolume: Double = 1
    /// Подгонка под экран площадки и пресеты площадок
    var screenFit = ScreenFit()
    var venuePresets: [VenuePreset] = []
    var venuePreset: UUID?
    /// Разрешение экрана сцены для каждого экрана (ключ — производитель-модель-серийник); нет — Default
    var resolutions: [String: DisplayModeRef] = [:]
    /// Каким был режим экрана до программы — вернуть при выходе
    var originalModes: [String: DisplayModeRef] = [:]
    /// Обои экрана сцены до программы — вернуть при выходе
    var previousWallpapers: [String: String] = [:]
    /// MIDI только из сетевого сеанса с Logic; выкл — ещё и USB-устройства этого Mac
    var acceptOnlyLogic = true

    // Старый формат: одна папка с видео «NN_название» и метки по номерам. Переносится в сет при запуске.
    var legacyFolderPath: String?
    var legacyMarkers: [String: [String: Double]] = [:]

    init() {}

    enum CodingKeys: String, CodingKey {
        case setlists, activeSetlist, logoPath, display, transition, transitionDuration, scale, markerBaseNote
        case live, logicMac, hideDock, hidePointer, restartScreen, restartImagePath, extrasImageDuration
        case playlists, extrasAudioDevice, extrasVolume, screenFit, venuePresets, venuePreset
        case resolutions, originalModes, previousWallpapers, acceptOnlyLogic, testWindow
        case legacyFolderPath = "folderPath", legacyMarkers = "markers"
        case crossfade, fadeOut
    }

    // Новые поля не ломают старый файл настроек
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        setlists = (try? c.decodeIfPresent([Setlist].self, forKey: .setlists)) ?? []
        activeSetlist = try? c.decodeIfPresent(UUID.self, forKey: .activeSetlist)
        logoPath = try? c.decodeIfPresent(String.self, forKey: .logoPath)
        display = (try? c.decodeIfPresent(DisplayChoice.self, forKey: .display)) ?? d.display
        scale = (try? c.decodeIfPresent(ScaleMode.self, forKey: .scale)) ?? d.scale
        markerBaseNote = (try? c.decodeIfPresent(Int.self, forKey: .markerBaseNote)) ?? d.markerBaseNote
        live = (try? c.decodeIfPresent(Bool.self, forKey: .live)) ?? false
        logicMac = try? c.decodeIfPresent(LinkTarget.self, forKey: .logicMac)
        hideDock = (try? c.decodeIfPresent(Bool.self, forKey: .hideDock)) ?? d.hideDock
        hidePointer = (try? c.decodeIfPresent(Bool.self, forKey: .hidePointer)) ?? d.hidePointer
        restartScreen = (try? c.decodeIfPresent(RestartScreen.self, forKey: .restartScreen)) ?? d.restartScreen
        restartImagePath = try? c.decodeIfPresent(String.self, forKey: .restartImagePath)
        extrasImageDuration = (try? c.decodeIfPresent(Double.self, forKey: .extrasImageDuration)) ?? d.extrasImageDuration
        playlists = (try? c.decodeIfPresent([Playlist].self, forKey: .playlists)) ?? []
        extrasAudioDevice = try? c.decodeIfPresent(String.self, forKey: .extrasAudioDevice)
        extrasVolume = (try? c.decodeIfPresent(Double.self, forKey: .extrasVolume)) ?? d.extrasVolume
        screenFit = (try? c.decodeIfPresent(ScreenFit.self, forKey: .screenFit)) ?? ScreenFit()
        venuePresets = (try? c.decodeIfPresent([VenuePreset].self, forKey: .venuePresets)) ?? []
        venuePreset = try? c.decodeIfPresent(UUID.self, forKey: .venuePreset)
        resolutions = (try? c.decodeIfPresent([String: DisplayModeRef].self, forKey: .resolutions)) ?? [:]
        originalModes = (try? c.decodeIfPresent([String: DisplayModeRef].self, forKey: .originalModes)) ?? [:]
        previousWallpapers = (try? c.decodeIfPresent([String: String].self, forKey: .previousWallpapers)) ?? [:]
        acceptOnlyLogic = (try? c.decodeIfPresent(Bool.self, forKey: .acceptOnlyLogic)) ?? true
        testWindow = (try? c.decodeIfPresent(Bool.self, forKey: .testWindow)) ?? false
        // Старый выбор «Window (test)» в списке экранов → кнопка тестового окна
        if display == .window {
            display = .firstExternal
            testWindow = true
        }
        legacyFolderPath = try? c.decodeIfPresent(String.self, forKey: .legacyFolderPath)
        legacyMarkers = (try? c.decodeIfPresent([String: [String: Double]].self, forKey: .legacyMarkers)) ?? [:]
        // Старые «crossfade» и «fadeOut» → переход и длительность
        if let t = try? c.decodeIfPresent(Transition.self, forKey: .transition) {
            transition = t
        } else if (try? c.decodeIfPresent(Bool.self, forKey: .crossfade)) == true {
            transition = .crossfade
        }
        transitionDuration = (try? c.decodeIfPresent(Double.self, forKey: .transitionDuration))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .fadeOut)) ?? d.transitionDuration
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(setlists, forKey: .setlists)
        try c.encodeIfPresent(activeSetlist, forKey: .activeSetlist)
        try c.encodeIfPresent(logoPath, forKey: .logoPath)
        try c.encode(display, forKey: .display)
        try c.encode(transition, forKey: .transition)
        try c.encode(transitionDuration, forKey: .transitionDuration)
        try c.encode(scale, forKey: .scale)
        try c.encode(markerBaseNote, forKey: .markerBaseNote)
        try c.encode(live, forKey: .live)
        try c.encodeIfPresent(logicMac, forKey: .logicMac)
        try c.encode(hideDock, forKey: .hideDock)
        try c.encode(hidePointer, forKey: .hidePointer)
        try c.encode(restartScreen, forKey: .restartScreen)
        try c.encodeIfPresent(restartImagePath, forKey: .restartImagePath)
        try c.encode(extrasImageDuration, forKey: .extrasImageDuration)
        try c.encode(playlists, forKey: .playlists)
        try c.encodeIfPresent(extrasAudioDevice, forKey: .extrasAudioDevice)
        try c.encode(extrasVolume, forKey: .extrasVolume)
        try c.encode(screenFit, forKey: .screenFit)
        try c.encode(venuePresets, forKey: .venuePresets)
        try c.encodeIfPresent(venuePreset, forKey: .venuePreset)
        try c.encode(resolutions, forKey: .resolutions)
        try c.encode(originalModes, forKey: .originalModes)
        try c.encode(previousWallpapers, forKey: .previousWallpapers)
        try c.encode(acceptOnlyLogic, forKey: .acceptOnlyLogic)
        try c.encode(testWindow, forKey: .testWindow)
        try c.encodeIfPresent(legacyFolderPath, forKey: .legacyFolderPath)
        if !legacyMarkers.isEmpty { try c.encode(legacyMarkers, forKey: .legacyMarkers) }
    }

    var active: Setlist? { setlists.first { $0.id == activeSetlist } }
}

/// Файлы программы в ~/Library/Application Support/LiveVideoSync/
enum Store {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("LiveVideoSync")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static let settingsURL = dir.appendingPathComponent("settings.json")
    /// Есть файл — программа завершилась штатно (Cmd+Q); нет — упала, сторож перезапустит
    static let cleanExitURL = dir.appendingPathComponent("clean-exit")
    /// Обновляется каждую секунду с главного потока — сторож видит зависание
    static let heartbeatURL = dir.appendingPathComponent("heartbeat")
    static let restartsURL = dir.appendingPathComponent("restarts")

    /// Чёрная картинка для обоев экрана сцены (Settings → Output → While the Player Restarts → Black)
    static let blackImageURL: URL? = {
        let url = dir.appendingPathComponent("black.png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return (try? data.write(to: url)) != nil ? url : nil
    }()

    static func loadSettings() -> Settings {
        guard let data = try? Data(contentsOf: settingsURL) else { return Settings() }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            // Повреждённый файл не должен мешать старту — откладываем копию и начинаем с нуля
            let backup = dir.appendingPathComponent("settings.broken.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: settingsURL, to: backup)
            Log.info("Настройки повреждены (\(error)), копия: \(backup.path)")
            return Settings()
        }
    }

    static func save(_ settings: Settings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        do {
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            Log.info("Не удалось сохранить настройки: \(error)")
        }
    }

    static func markRunning() {
        try? FileManager.default.removeItem(at: cleanExitURL)
    }

    static func markCleanExit() {
        FileManager.default.createFile(atPath: cleanExitURL.path, contents: Data())
    }

    static func heartbeat() {
        let now = Date()
        if !FileManager.default.fileExists(atPath: heartbeatURL.path) {
            FileManager.default.createFile(atPath: heartbeatURL.path, contents: Data())
        }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: heartbeatURL.path)
    }
}
