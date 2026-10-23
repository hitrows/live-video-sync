import AppKit
import CoreMIDI

// MIDI Link — утилита для MacBook с Logic (macOS 11+):
// подключить сетевой MIDI к Mac с видео одной кнопкой. Подключение остаётся и после закрытия утилиты.
// Для проверок: open MIDILink.app --args --connect "Имя Mac" | --disconnect

enum Log {
    private static let queue = DispatchQueue(label: "midilink.log")
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MIDILink")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("midilink.log")
    }()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static let handle: FileHandle? = {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async { handle?.write(line.data(using: .utf8)!) }
    }
}

final class Controller: NSObject {
    let link = NetworkMIDILink()
    private let window: NSWindow
    private let ownLabel = NSTextField(labelWithString: "")
    private let peerPopup = NSPopUpButton()
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    private let statusDot = NSTextField(labelWithString: "●")
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let defaults = UserDefaults.standard
    private var pendingConnect: String?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "MIDI Link"
        window.isReleasedWhenClosed = false
        buildUI()

        link.log = { Log.info($0) }
        link.onChange = { [weak self] in self?.refresh() }
        link.keepConnectedTo = savedTarget
        link.start()
        refresh()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        let title = NSTextField(labelWithString: "Video Mac")
        title.font = .boldSystemFont(ofSize: 13)
        peerPopup.target = self
        peerPopup.action = #selector(peerChosen)
        connectButton.target = self
        connectButton.action = #selector(connectPressed)
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnectPressed)
        disconnectButton.bezelStyle = .rounded
        statusDot.font = .systemFont(ofSize: 16)
        statusLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        ownLabel.textColor = .secondaryLabelColor
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.stringValue = "The connection stays after you quit MIDI Link (while the video Mac's player is running it also reconnects by itself). In Logic use the network session as the MTC/MMC destination and as the marker track output."

        let peerRow = NSStackView(views: [title, peerPopup])
        peerRow.spacing = 10
        peerPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let buttons = NSStackView(views: [connectButton, disconnectButton])
        buttons.spacing = 10
        let status = NSStackView(views: [statusDot, statusLabel])
        status.spacing = 6
        let stack = NSStackView(views: [status, peerRow, buttons, ownLabel, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            hintLabel.widthAnchor.constraint(equalToConstant: 400),
        ])
        window.contentView = content
    }

    /// Команда из аргументов запуска — выполнить, когда нужный Mac найдётся в сети
    func handle(arguments: [String]) {
        if let i = arguments.firstIndex(of: "--connect"), i + 1 < arguments.count {
            pendingConnect = arguments[i + 1]
            Log.info("Команда: подключиться к «\(arguments[i + 1])»")
            refresh()
        }
        if arguments.contains("--disconnect") {
            Log.info("Команда: отключить всё")
            disconnectPressed()
        }
    }

    /// Найденные в сети + запомненный (объявление в сети мигает, но адрес рабочий)
    private var choices: [NetworkMIDILink.Peer] {
        var list = link.peers
        if let saved = savedTarget, !list.contains(where: { $0.name == saved.name }) { list.append(saved) }
        return list
    }

    private var savedTarget: NetworkMIDILink.Peer? {
        guard let name = defaults.string(forKey: "targetName"), let address = defaults.string(forKey: "targetAddress") else { return nil }
        return NetworkMIDILink.Peer(name: name, address: address, ip: defaults.string(forKey: "targetIP"))
    }

    private var selectedPeer: NetworkMIDILink.Peer? {
        guard peerPopup.isEnabled, let title = peerPopup.titleOfSelectedItem else { return nil }
        return choices.first { $0.name == title }
    }

    @objc private func peerChosen() {
        refresh()
    }

    @objc private func connectPressed() {
        guard let peer = selectedPeer else { return }
        connect(peer)
    }

    private func connect(_ peer: NetworkMIDILink.Peer) {
        defaults.set(peer.name, forKey: "targetName")
        defaults.set(peer.address, forKey: "targetAddress")
        if let ip = peer.ip { defaults.set(ip, forKey: "targetIP") }
        link.keepConnectedTo = peer
        // Одна связь — с выбранным Mac
        if link.connections.contains(where: { $0.address != peer.address }) { link.disconnectAll() }
        link.connect(peer)
    }

    @objc private func disconnectPressed() {
        defaults.removeObject(forKey: "targetName")
        defaults.removeObject(forKey: "targetAddress")
        defaults.removeObject(forKey: "targetIP")
        link.keepConnectedTo = nil
        link.disconnectAll()
    }

    private func refresh() {
        // Свежий IP выбранного Mac — запомнить про запас
        if let saved = savedTarget, let found = link.peers.first(where: { $0.name == saved.name }), found.address != saved.address {
            defaults.set(found.address, forKey: "targetAddress")
            link.keepConnectedTo = NetworkMIDILink.Peer(name: found.name, address: found.address, ip: found.ip ?? saved.ip)
        }
        if let saved = savedTarget, let found = link.peers.first(where: { $0.name == saved.name }),
           let ip = found.ip, ip != saved.ip {
            defaults.set(ip, forKey: "targetIP")
            link.keepConnectedTo?.ip = ip
            Log.info("Запомнен IP «\(saved.name)»: \(ip)")
        }
        if let name = pendingConnect, let peer = link.peers.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
            pendingConnect = nil
            connect(peer)
        }

        guard link.hasSession else {
            statusDot.textColor = .systemOrange
            statusLabel.stringValue = "No network MIDI session on this Mac"
            hintLabel.stringValue = "Create it once: Audio MIDI Setup → Window → Show MIDI Studio → double-click Network → under My Sessions click +, tick Session 1. Then reopen MIDI Link."
            peerPopup.isEnabled = false
            connectButton.isEnabled = false
            disconnectButton.isEnabled = false
            return
        }

        let names = choices.map(\.name)
        let previous = peerPopup.titleOfSelectedItem
        peerPopup.removeAllItems()
        if names.isEmpty {
            peerPopup.addItem(withTitle: "Searching the network…")
            peerPopup.isEnabled = false
        } else {
            peerPopup.addItems(withTitles: names)
            peerPopup.isEnabled = true
            let preferred = [previous, link.keepConnectedTo?.name, link.connections.first?.name].compactMap { $0 }
            if let pick = preferred.first(where: { names.contains($0) }) { peerPopup.selectItem(withTitle: pick) }
        }

        let connections = link.connections
        if connections.isEmpty {
            statusDot.textColor = .systemRed
            statusLabel.stringValue = "Not connected"
        } else {
            let ok = connections.contains { $0.state == "connected" || $0.state == "running" }
            statusDot.textColor = ok ? .systemGreen : .systemOrange
            statusLabel.stringValue = "Connected to " + connections.map(\.name).joined(separator: ", ")
        }
        let selected = selectedPeer
        connectButton.isEnabled = selected != nil && !(selected.map(link.isConnected) ?? false)
        disconnectButton.isEnabled = !connections.isEmpty
        ownLabel.stringValue = "This Mac: \(link.ownName.isEmpty ? "…" : link.ownName)  ·  MIDI port in Logic: \(link.sessionName)"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: Controller!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit MIDI Link", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main

        Log.info("=== MIDI Link запущен, \(ProcessInfo.processInfo.operatingSystemVersionString)")
        controller = Controller()
        controller.handle(arguments: CommandLine.arguments)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("=== MIDI Link закрыт (подключение остаётся: \(controller.link.connections.map(\.name).joined(separator: ", ")))")
    }
}

UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
