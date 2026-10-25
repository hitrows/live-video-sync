import AppKit
import CoreGraphics

/// Режим экрана, который можно запомнить (ID режима меняется между подключениями — храним размеры и частоту)
struct DisplayModeRef: Codable, Equatable, Hashable {
    var width: Int
    var height: Int
    var refresh: Double
    var hiDPI: Bool

    var title: String {
        var s = "\(width)×\(height)"
        if refresh > 0 { s += " · \(Int(refresh.rounded())) Hz" }
        if hiDPI { s += " · HiDPI" }
        return s
    }
}

/// Разрешение экрана сцены: все режимы, которые сообщает экран (включая скрытые), переключение официальным API.
/// Произвольные разрешения (подмена EDID, виртуальные экраны) не делаем — закрытые API, риск чёрного экрана.
enum DisplayModes {
    static func all(_ display: CGDirectDisplayID) -> [(ref: DisplayModeRef, mode: CGDisplayMode)] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else { return [] }
        var seen = Set<DisplayModeRef>()
        var result: [(DisplayModeRef, CGDisplayMode)] = []
        for mode in modes where mode.isUsableForDesktopGUI() {
            let ref = ref(mode)
            if seen.insert(ref).inserted { result.append((ref, mode)) }
        }
        return result.sorted {
            ($0.0.width * $0.0.height, $0.0.refresh, $0.0.hiDPI ? 1 : 0) > ($1.0.width * $1.0.height, $1.0.refresh, $1.0.hiDPI ? 1 : 0)
        }
    }

    static func ref(_ mode: CGDisplayMode) -> DisplayModeRef {
        DisplayModeRef(width: mode.width, height: mode.height, refresh: mode.refreshRate, hiDPI: mode.pixelWidth > mode.width)
    }

    static func current(_ display: CGDirectDisplayID) -> DisplayModeRef? {
        CGDisplayCopyDisplayMode(display).map(ref)
    }

    /// Поставить режим. Сохраняется и после сбоя программы (экран не мигает при перезапуске);
    /// прежний режим программа возвращает сама при штатном выходе.
    @discardableResult
    static func set(_ wanted: DisplayModeRef, on display: CGDirectDisplayID) -> Bool {
        guard current(display) != wanted else { return true }
        guard let mode = all(display).first(where: { $0.ref == wanted })?.mode else {
            Log.info("Разрешение \(wanted.title) экран не поддерживает")
            return false
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        Log.info("Разрешение экрана: \(wanted.title) — \(result == .success ? "ок" : "ошибка \(result.rawValue)")")
        return result == .success
    }

    static func displayKey(_ ref: DisplayRef) -> String {
        "\(ref.vendor)-\(ref.model)-\(ref.serial)"
    }
}
