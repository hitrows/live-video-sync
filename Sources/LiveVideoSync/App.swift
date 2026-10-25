import AppKit
import SwiftUI

/// Состояние окна, общее для окна и строки меню
final class UIState: ObservableObject {
    static let shared = UIState()

    enum Mode: Hashable { case show, screenFit }
    enum SidebarItem: Hashable { case setlist(UUID), playlist(UUID) }

    @Published var mode: Mode = .show
    @Published var selection: SidebarItem?

    var selectedSetlist: UUID? {
        if case .setlist(let id) = selection { return id }
        return nil
    }

    var selectedPlaylist: UUID? {
        if case .playlist(let id) = selection { return id }
        return nil
    }

    func newPlaylist(_ show: Show) {
        let id = show.newPlaylist()
        mode = .show
        selection = .playlist(id)
    }

    /// Go Live — сразу; Stop Output — только через подтверждение.
    /// Return окно не закрывает: остановить вывод можно только щелчком, случайно нажать нельзя.
    func toggleLive(_ show: Show) {
        guard show.settings.live else {
            show.toggleLive()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Stop output?"
        alert.informativeText = "The stage screen shows the wallpaper until you press Go Live again."
        alert.alertStyle = .warning
        let stop = alert.addButton(withTitle: "Stop Output")
        stop.hasDestructiveAction = true
        stop.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { show.toggleLive() }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    func newSetlist(_ show: Show) {
        let id = show.newSetlist()
        mode = .show
        selection = .setlist(id)
    }

    /// File → Add Files… — в открытый сет или плейлист
    func addFiles(_ show: Show) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        if let playlist = selectedPlaylist {
            guard panel.runModal() == .OK else { return }
            show.addFiles(panel.urls, toPlaylist: playlist)
            return
        }
        guard let id = selectedSetlist ?? show.settings.activeSetlist ?? show.settings.setlists.first?.id else { return }
        guard panel.runModal() == .OK else { return }
        show.addFiles(panel.urls, to: id)
        selection = .setlist(id)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SIGTERM (деплой) — выходим без вопроса
    static var quitWithoutAsking = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Show.shared.start()
        let ui = UIState.shared
        if ui.selection == nil, let id = Show.shared.settings.activeSetlist ?? Show.shared.settings.setlists.first?.id {
            ui.selection = .setlist(id)
        }
    }

    // Закрыли окно управления — трансляция продолжается
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Cmd+Q гасит экран на сцене — спрашиваем. По умолчанию (Enter) — Cancel.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.quitWithoutAsking { return .terminateNow }
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
}

struct LiveVideoSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Live Video Sync", id: "main") {
            MainView(show: .shared, ui: .shared)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                FileMenu(show: .shared, ui: .shared)
            }
            CommandMenu("Show") {
                ShowMenu(show: .shared, ui: .shared)
            }
            CommandGroup(replacing: .help) {
                Button("Live Video Sync Help") { HelpWindow.show() }
                    .keyboardShortcut("?")
            }
        }

        SwiftUI.Settings {
            SettingsView(show: .shared)
        }
    }
}

private struct FileMenu: View {
    @ObservedObject var show: Show
    @ObservedObject var ui: UIState

    var body: some View {
        Button("New Setlist") { ui.newSetlist(show) }
            .keyboardShortcut("n")
        Button("New Playlist") { ui.newPlaylist(show) }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        Divider()
        Button("Add Files…") { ui.addFiles(show) }
            .keyboardShortcut("o")
            .disabled(show.settings.setlists.isEmpty && ui.selectedPlaylist == nil)
    }
}

/// Меню Show: Go Live ⌘L, Logo ⌘G, Blackout ⌘B, Resume Sync ⌘R | Test Pattern ⌘T | Show ⌘1, Screen Fit ⌘2
private struct ShowMenu: View {
    @ObservedObject var show: Show
    @ObservedObject var ui: UIState

    var body: some View {
        Button(show.settings.live ? "Stop Output…" : "Go Live") { ui.toggleLive(show) }
            .keyboardShortcut("l")
        Toggle("Logo", isOn: Binding(get: { show.manualLogo }, set: { _ in show.toggleLogo() }))
            .keyboardShortcut("g")
        Toggle("Blackout", isOn: Binding(get: { show.manualBlack }, set: { _ in show.toggleBlackout() }))
            .keyboardShortcut("b")
        Button("Resume Sync") { show.resumeSync() }
            .keyboardShortcut("r")
            .disabled(!show.isManual)
        Divider()
        Toggle("Test Pattern", isOn: $show.testPattern)
            .keyboardShortcut("t")
        Divider()
        Picker("Mode", selection: $ui.mode) {
            Text("Show").tag(UIState.Mode.show).keyboardShortcut("1")
            Text("Screen Fit").tag(UIState.Mode.screenFit).keyboardShortcut("2")
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}
