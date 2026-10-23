import AppKit
import SwiftUI

// Процесс-сторож — тот же файл с ключом --watchdog, без интерфейса
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == Watchdog.argument {
    Watchdog.run(arguments: Array(CommandLine.arguments.dropFirst(2)))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    /// SIGTERM (деплой) — выходим без вопроса
    var quitWithoutAsking = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        setupMenu()
        Show.shared.start()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Live Video Sync"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = NSHostingView(rootView: ControlView(show: Show.shared))
        window.center()
        window.setFrameAutosaveName("ControlWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Закрыли окно управления — трансляция продолжается
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    // Cmd+Q гасит экран на сцене — спрашиваем. По умолчанию (Enter) — Cancel.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitWithoutAsking { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Live Video Sync?"
        alert.informativeText = "The stage screen goes black when the app quits.\nClosing the window keeps the video running."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit")
        let quit = alert.runModal() == .alertSecondButtonReturn
        if quit { Log.info("Выход подтверждён пользователем") }
        return quit ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        Store.markCleanExit()
        Log.info("=== Live Video Sync завершается")
    }

    @objc private func showHelp() { HelpWindow.show() }
    @objc private func toggleBlackout() { Show.shared.toggleBlackout() }
    @objc private func toggleLogo() { Show.shared.toggleLogo() }
    @objc private func setScale(_ sender: NSMenuItem) { Show.shared.setScale(ScaleMode.allCases[sender.tag]) }
    @objc private func toggleLive() { Show.shared.toggleLive() }

    private func setupMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Live Video Sync", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Без меню Edit в текстовых полях не работают Cmd+C / Cmd+V
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let showItem = NSMenuItem()
        main.addItem(showItem)
        let showMenu = NSMenu(title: "Show")
        for (title, action, key) in [("Go Live / Stop Output", #selector(toggleLive), "l"),
                                     ("Blackout", #selector(toggleBlackout), "b"),
                                     ("Logo", #selector(toggleLogo), "g")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            showMenu.addItem(item)
        }
        showMenu.addItem(.separator())
        for (index, mode) in ScaleMode.allCases.enumerated() {
            let item = NSMenuItem(title: "Scale: \(mode.title)", action: #selector(setScale(_:)), keyEquivalent: "\(index + 1)")
            item.target = self
            item.tag = index
            showMenu.addItem(item)
        }
        showItem.submenu = showMenu

        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        let help = NSMenuItem(title: "Live Video Sync Help", action: #selector(showHelp), keyEquivalent: "?")
        help.target = self
        helpMenu.addItem(help)
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }
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

let delegate = AppDelegate()

// SIGTERM (pkill, деплой) — завершаемся штатно, это не сбой
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    delegate.quitWithoutAsking = true
    NSApp.terminate(nil)
}
sigterm.resume()

let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
