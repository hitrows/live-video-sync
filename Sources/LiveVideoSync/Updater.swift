import AppKit
import SwiftUI

/// Обновления из GitHub Releases: проверка при запуске, меню Check for Updates…, Settings → About.
/// Во время шоу ничего не ставим и не перезапускаем: экран сцены погас бы.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let notes: String
        let zip: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate, available(Release), downloading, installing, failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Включено — при запуске ставит новую версию сам, без вопроса
    @Published var autoInstall: Bool { didSet { defaults.set(autoInstall, forKey: Key.auto) } }
    @Published private(set) var lastChecked: Date?

    private let defaults = UserDefaults.standard
    private enum Key {
        static let auto = "autoInstallUpdates", lastChecked = "lastUpdateCheck", skipped = "skippedVersion"
    }
    private static let feed = URL(string: "https://api.github.com/repos/hitrows/live-video-sync/releases/latest")!
    private var progressWindow: NSWindow?

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }

    var busy: Bool { [.checking, .downloading, .installing].contains(state) }

    private init() {
        autoInstall = defaults.bool(forKey: Key.auto)
        lastChecked = defaults.object(forKey: Key.lastChecked) as? Date
    }

    // MARK: Проверка

    /// При запуске. Перезапуск во время шоу (сбой, сторож) — не проверяем вовсе. Нет сети — молча.
    func checkAtLaunch(duringShow: Bool) {
        guard !duringShow else {
            Log.info("Обновления: запуск во время шоу — не проверяем")
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard let release = await fetch(quietly: true),
                  release.version != defaults.string(forKey: Key.skipped),
                  !Show.shared.settings.live else { return }
            if autoInstall {
                Log.info("Обновления: ставлю \(release.version) сам (автообновление)")
                install(release)
            } else {
                offer(release)
            }
        }
    }

    /// Меню и Settings → About: ответ показываем всегда, даже «уже последняя»
    func checkNow() {
        guard !busy else { return }
        Task {
            guard let release = await fetch(quietly: false) else { return }
            offer(release)
        }
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let assets: [Asset]
    }

    private func fetch(quietly: Bool) async -> Release? {
        state = .checking
        do {
            var request = URLRequest(url: Self.feed, timeoutInterval: 10)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError("The update server didn’t respond. Try again later.")
            }
            let latest = try JSONDecoder().decode(GitHubRelease.self, from: data)
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Key.lastChecked)
            let version = String(latest.tag_name.drop { $0 == "v" })
            guard Self.isNewer(version, than: Self.version),
                  let zip = latest.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
                state = .upToDate
                if !quietly { upToDateAlert() }
                return nil
            }
            let release = Release(version: version, notes: latest.body ?? "", zip: zip.browser_download_url)
            state = .available(release)
            return release
        } catch {
            Log.info("Обновления: проверка не удалась — \(error.localizedDescription)")
            state = quietly ? .idle : .failed(Self.message(error))
            if !quietly { errorAlert(error) }
            return nil
        }
    }

    /// «0.10» новее «0.9»: сравниваем числа по частям
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Окна

    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "A new version of Live Video Sync is available!"
        alert.informativeText = "Live Video Sync \(release.version) is available — you have \(Self.version). Would you like to update now?"
        if !release.notes.isEmpty { alert.accessoryView = Self.notesView(release.notes) }
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Automatically install updates in the future"
        alert.suppressionButton?.state = autoInstall ? .on : .off
        let response = alert.runModal()
        autoInstall = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn:
            install(release)
        case .alertThirdButtonReturn:
            defaults.set(release.version, forKey: Key.skipped)
            Log.info("Обновления: версия \(release.version) пропущена")
        default:
            break
        }
    }

    /// Что нового — из описания релиза на GitHub (Markdown)
    private static func notesView(_ notes: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 360, height: 140)
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.textContainerInset = NSSize(width: 4, height: 6)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: notes, options: options)).map { NSMutableAttributedString($0) }
            ?? NSMutableAttributedString(string: notes)
        let all = NSRange(location: 0, length: parsed.length)
        parsed.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), range: all)
        parsed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: all)
        text.textStorage?.setAttributedString(parsed)
        return scroll
    }

    private func upToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You’re up to date!"
        alert.informativeText = "Live Video Sync \(Self.version) is currently the newest version available."
        alert.runModal()
    }

    private func errorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Update Error"
        alert.informativeText = Self.message(error)
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func message(_ error: Error) -> String {
        if let e = error as? UpdateError { return e.message }
        if (error as? URLError) != nil { return "Can’t reach the update server. Check the internet connection." }
        return error.localizedDescription
    }

    // MARK: Установка

    func install(_ release: Release) {
        guard !Show.shared.settings.live else {
            let alert = NSAlert()
            alert.messageText = "Stop the output to update"
            alert.informativeText = "Updating restarts Live Video Sync, and the stage screen goes black. Stop Output first, then update."
            alert.runModal()
            return
        }
        guard !busy else { return }
        state = .downloading
        showProgress()
        Task {
            do {
                let app = try await download(release)
                // Пока качали, могли нажать Go Live — шоу не прерываем, поставим в другой раз
                guard !Show.shared.settings.live else {
                    Log.info("Обновления: пока качали, включили эфир — установка отложена")
                    state = .available(release)
                    hideProgress()
                    return
                }
                state = .installing
                try relaunch(replacingWith: app)
            } catch {
                Log.info("Обновления: установка не удалась — \(error.localizedDescription)")
                state = .failed(Self.message(error))
                hideProgress()
                errorAlert(error)
            }
        }
    }

    /// Скачать, распаковать и убедиться, что внутри действительно Live Video Sync нужной версии
    private func download(_ release: Release) async throws -> URL {
        Log.info("Обновления: скачиваю \(release.version)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LiveVideoSync-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (file, response) = try await URLSession.shared.download(from: release.zip)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The update couldn’t be downloaded.") }
        let zip = dir.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: file, to: zip)
        try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        let found = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "app" }
        guard let app = found, let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.infoDictionary?["CFBundleShortVersionString"] as? String == release.version else {
            throw UpdateError("The downloaded update isn’t Live Video Sync \(release.version).")
        }
        do {
            try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        } catch {
            throw UpdateError("The downloaded update is damaged.")
        }
        return app
    }

    /// Скрипт ждёт выхода программы, меняет её на новую и открывает. Старая лежит рядом, пока новая не на месте.
    private func relaunch(replacingWith app: URL) throws {
        let current = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw UpdateError("Live Video Sync can’t replace itself in “\(current.deletingLastPathComponent().lastPathComponent)”. Move the app to the Applications folder and try again.")
        }
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.old"
        if mv "$2" "$2.old" && mv "$3" "$2"; then rm -rf "$2.old"; else [ -d "$2" ] || mv "$2.old" "$2"; fi
        xattr -dr com.apple.quarantine "$2" 2>/dev/null
        open "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(getpid()), current.path, app.path]
        try process.run()
        Log.info("Обновления: перезапуск с новой версией")
        AppDelegate.quitWithoutAsking = true
        NSApp.terminate(nil)
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw UpdateError("\(tool) failed") }
        }.value
    }

    private func showProgress() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: UpdateProgressView(updater: self)))
        window.styleMask = [.titled]
        window.title = "Updating Live Video Sync"
        window.center()
        window.makeKeyAndOrderFront(nil)
        progressWindow = window
    }

    private func hideProgress() {
        progressWindow?.close()
        progressWindow = nil
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct UpdateProgressView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 8) {
                Text(updater.state == .installing ? "Installing update…" : "Downloading update…")
                    .font(.headline)
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 240)
                Text("Live Video Sync restarts by itself when it’s ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}
