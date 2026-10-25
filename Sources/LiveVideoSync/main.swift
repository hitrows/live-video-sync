import AppKit
import SwiftUI

// Процесс-сторож — тот же файл с ключом --watchdog, без интерфейса
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == Watchdog.argument {
    Watchdog.run(arguments: Array(CommandLine.arguments.dropFirst(2)))
}

// Не спрашивать «восстановить окна?» после аварийного завершения
UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
Log.info("=== Live Video Sync \(version) запущен, \(ProcessInfo.processInfo.operatingSystemVersionString)")
Log.info("Экраны: \(OutputController.screenList())")

// Без App Nap и сна: иначе macOS притормозит видео, когда окно управления в фоне
let activity = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
    reason: "Live video output")

Store.markRunning()
Store.heartbeat()
Watchdog.spawn()

// SIGTERM (pkill, деплой) — завершаемся штатно, это не сбой
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    AppDelegate.quitWithoutAsking = true
    NSApp.terminate(nil)
}
sigterm.resume()

LiveVideoSyncApp.main()
