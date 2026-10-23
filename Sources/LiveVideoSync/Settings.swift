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

struct Settings: Codable, Equatable {
    var folderPath: String?
    var display: DisplayChoice = .firstExternal
    var fadeOut: Double = 0.7
    var fadeIn: Double = 0.7
    var crossfade = false
    var scale: ScaleMode = .fit
    var markerBaseNote = 36
    /// Выученные начала песен (секунды MTC): папка → номер песни → позиция.
    /// По номеру, а не по имени файла: видео можно заменять и переименовывать. Своя папка — свой сет и свои метки.
    var markers: [String: [String: Double]] = [:]
    /// Была ли трансляция включена — после перезапуска включаем снова
    var live = false
    /// С кем держать сетевой MIDI (плеер сам переподключается)
    var logicMac: LinkTarget?

    init() {}

    // Новые поля не ломают старый файл настроек
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
        display = (try? c.decodeIfPresent(DisplayChoice.self, forKey: .display)) ?? d.display
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? d.fadeOut
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? d.fadeIn
        crossfade = try c.decodeIfPresent(Bool.self, forKey: .crossfade) ?? d.crossfade
        scale = (try? c.decodeIfPresent(ScaleMode.self, forKey: .scale)) ?? d.scale
        markerBaseNote = try c.decodeIfPresent(Int.self, forKey: .markerBaseNote) ?? d.markerBaseNote
        markers = try c.decodeIfPresent([String: [String: Double]].self, forKey: .markers) ?? [:]
        live = try c.decodeIfPresent(Bool.self, forKey: .live) ?? false
        logicMac = try? c.decodeIfPresent(LinkTarget.self, forKey: .logicMac)
    }
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
