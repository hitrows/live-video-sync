import CoreMedia
import Foundation

/// Лог в файл ~/Library/Logs/LiveVideoSync/lvs.log.
/// Пишет в отдельной очереди, ошибки записи молча игнорирует (лог не должен ронять программу).
enum Log {
    private static let queue = DispatchQueue(label: "lvs.log")
    private static let maxSize: UInt64 = 10 * 1024 * 1024

    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LiveVideoSync")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lvs.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let handle: FileHandle? = {
        let fm = FileManager.default
        // Слишком большой лог — начинаем заново
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > maxSize {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()

    static func info(_ message: String) {
        let date = Date()
        queue.async {
            let line = "\(formatter.string(from: date)) [\(getpid())] \(message)\n"
            if let data = line.data(using: .utf8) {
                try? handle?.write(contentsOf: data)
            }
        }
    }
}

/// Часы хоста в секундах — общая шкала для MIDI-меток времени, таймера и AVPlayer
enum HostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    static func ticks(_ seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1e9 * Double(timebase.denom) / Double(timebase.numer))
    }

    static var now: Double { seconds(mach_absolute_time()) }

    static func cmTime(_ seconds: Double) -> CMTime {
        CMClockMakeHostTimeFromSystemUnits(ticks(seconds))
    }
}
