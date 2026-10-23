import AppKit
import Foundation

/// Сторож: отдельный процесс (тот же исполняемый файл с ключом --watchdog).
/// Программа упала или зависла — открывает её снова; она сама поднимет трансляцию с последними настройками.
/// Штатный выход (Cmd+Q) — сторож просто завершается.
enum Watchdog {
    static let argument = "--watchdog"
    /// Столько секунд без сердцебиения — считаем, что программа зависла
    static let hangTimeout = 8.0
    static let maxRestarts = 5
    static let restartWindow = 120.0

    /// Запуск сторожа из программы
    static func spawn() {
        guard let exe = Bundle.main.executablePath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = [argument, String(getpid()), Bundle.main.bundlePath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            Log.info("Сторож запущен, pid \(process.processIdentifier)")
        } catch {
            Log.info("Сторож не запустился: \(error)")
        }
    }

    /// Точка входа процесса-сторожа
    static func run(arguments: [String]) -> Never {
        guard arguments.count >= 2, let pid = pid_t(arguments[0]) else { exit(1) }
        let bundlePath = arguments[1]
        // Отвязываемся от группы процессов программы
        setsid()
        var lastLoop = Date()
        var heartbeatSeen = false

        while true {
            sleep(1)
            let now = Date()
            // Mac спал — паузу в сердцебиении не считаем зависанием
            let slept = now.timeIntervalSince(lastLoop) > 3
            lastLoop = now

            let alive = kill(pid, 0) == 0 || errno == EPERM
            if !alive { break }

            if let modified = (try? FileManager.default.attributesOfItem(atPath: Store.heartbeatURL.path))?[.modificationDate] as? Date {
                let age = now.timeIntervalSince(modified)
                if age < 2 { heartbeatSeen = true }
                if heartbeatSeen, !slept, age > hangTimeout {
                    Log.info("Сторож: программа не отвечает \(Int(age)) с — завершаю её")
                    kill(pid, SIGKILL)
                    sleep(1)
                    break
                }
            }
        }

        if FileManager.default.fileExists(atPath: Store.cleanExitURL.path) {
            Log.info("Сторож: штатный выход программы, завершаюсь")
            exit(0)
        }

        // Не перезапускать бесконечно, если программа падает сразу после старта
        let now = Date().timeIntervalSince1970
        let history = ((try? String(contentsOf: Store.restartsURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { Double($0) }
            .filter { now - $0 < restartWindow }
        if history.count >= maxRestarts {
            Log.info("Сторож: \(history.count) перезапусков за \(Int(restartWindow)) с — больше не перезапускаю")
            exit(1)
        }
        try? (history + [now]).map { String($0) }.joined(separator: "\n")
            .write(to: Store.restartsURL, atomically: true, encoding: .utf8)

        Log.info("Сторож: программа завершилась аварийно — перезапускаю")
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [bundlePath]
        try? open.run()
        open.waitUntilExit()
        exit(0)
    }
}
