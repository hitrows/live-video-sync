import AppKit
import Combine
import IOKit.pwr_mgt

/// Что показывает монитор в окне управления
struct MonitorStatus: Equatable {
    var linkOK = false
    var link = "—"
    var mtcRunning = false
    var timecode = "--:--:--:--"
    var rate = ""
    var screenText = "—"
    var detail = ""
    var outputText = "—"
    var sources = ""
}

/// Сердце программы: MIDI → Director → VideoEngine, настройки, монитор
final class Show: ObservableObject {
    static let shared = Show()

    @Published var settings: Settings {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }
    @Published private(set) var songs: [VideoFile] = []
    @Published private(set) var logoURL: URL?
    @Published private(set) var problems: [String] = []
    @Published private(set) var scanning = false
    @Published private(set) var status = MonitorStatus()
    @Published private(set) var manualBlack = false
    @Published private(set) var manualLogo = false

    let director = Director()
    let engine = VideoEngine()
    let midi = MIDIInput()
    let link = NetworkMIDILink()
    /// Найденные в сети Mac + запомненный Logic Mac (для выбора в окне)
    @Published private(set) var linkChoices: [LinkTarget] = []
    private(set) lazy var output = OutputController(engine: engine)

    private var timer: Timer?
    private var ticks = 0
    private var sleepAssertion: IOPMAssertionID = 0

    private init() {
        settings = Store.loadSettings()
    }

    func start() {
        applyToEngine()
        engine.urlForCue = { [weak self] id in self?.songs.first { $0.id == id }?.url }
        director.onCueLearned = { [weak self] id, position in self?.learned(id, at: position) }
        midi.onEvents = { [weak self] events in
            guard let self else { return }
            for (event, host) in events {
                if case .sysex(let payload) = event {
                    let hex = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                    Log.info("SysEx: F0 \(hex) F7 → \(MTCSysex.parse(payload))")
                }
                self.director.handle(event, host: host)
            }
        }
        midi.start()
        link.log = { Log.info("Сеть MIDI: " + $0) }
        link.onChange = { [weak self] in self?.updateLinkChoices() }
        link.keepConnectedTo = settings.logicMac.map { NetworkMIDILink.Peer(name: $0.name, address: $0.address, ip: $0.ip) }
        link.start()
        preventDisplaySleep()

        output.choice = settings.display
        output.live = settings.live
        if settings.live { Log.info("Трансляция включается сразу (была включена при прошлом запуске)") }
        rescan()

        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Действия

    func toggleLive() {
        settings.live.toggle()
        Log.info(settings.live ? "В эфир" : "Трансляция выключена")
    }

    func connectLogic(_ target: LinkTarget) {
        settings.logicMac = target
        let peer = NetworkMIDILink.Peer(name: target.name, address: target.address, ip: target.ip)
        link.keepConnectedTo = peer
        if link.connections.contains(where: { $0.address != target.address }) { link.disconnectAll() }
        link.connect(peer)
    }

    func disconnectLogic() {
        settings.logicMac = nil
        link.keepConnectedTo = nil
        link.disconnectAll()
    }

    private func updateLinkChoices() {
        var list = link.peers.map { LinkTarget(name: $0.name, address: $0.address, ip: $0.ip) }
        if let saved = settings.logicMac {
            if let found = list.first(where: { $0.name == saved.name }) {
                // Запомнить свежий IP Logic Mac — пригодится, если имя .local перестанет находиться
                if let ip = found.ip, ip != saved.ip {
                    settings.logicMac?.ip = ip
                    link.keepConnectedTo?.ip = ip
                    Log.info("Logic Mac: запомнен IP \(ip)")
                }
            } else {
                list.append(saved)
            }
        }
        if list != linkChoices { linkChoices = list }
    }

    func toggleBlackout() {
        director.manualBlack.toggle()
        manualBlack = director.manualBlack
        Log.info("Затемнение: \(manualBlack ? "вкл" : "выкл")")
    }

    func toggleLogo() {
        director.manualLogo.toggle()
        manualLogo = director.manualLogo
        Log.info("Ручной логотип: \(manualLogo ? "вкл" : "выкл")")
    }

    func setScale(_ mode: ScaleMode) {
        settings.scale = mode
        Log.info("Масштаб: \(mode.title)")
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        if let path = settings.folderPath { panel.directoryURL = URL(fileURLWithPath: path) }
        if panel.runModal() == .OK, let url = panel.url {
            settings.folderPath = url.path
        }
    }

    /// Метки текущей папки: номер песни → начало в Logic
    var markers: [Int: Double] {
        guard let folder = settings.folderPath, let list = settings.markers[folder] else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    private func setMarker(_ id: Int, _ position: Double?) {
        guard let folder = settings.folderPath else { return }
        var list = settings.markers[folder] ?? [:]
        list[String(id)] = position
        settings.markers[folder] = list.isEmpty ? nil : list
    }

    func resetMarkers() {
        if let folder = settings.folderPath { settings.markers[folder] = nil }
        rebuildCues()
        Log.info("Метки сброшены")
    }

    func resetMarker(_ song: VideoFile) {
        setMarker(song.id, nil)
        rebuildCues()
    }

    func rescan() {
        guard let path = settings.folderPath else {
            songs = []
            logoURL = nil
            problems = ["Choose the video folder"]
            rebuildCues()
            return
        }
        scanning = true
        let folder = URL(fileURLWithPath: path)
        Task { @MainActor in
            let scan = await Library.scan(folder: folder)
            self.apply(scan)
        }
    }

    // MARK: - Внутреннее

    private func apply(_ scan: LibraryScan) {
        scanning = false
        songs = scan.songs
        logoURL = scan.logo
        problems = scan.problems
        engine.logo.load(scan.logo)
        engine.reloadSongs()
        rebuildCues()
        Log.info("Папка: \(scan.songs.count) песен, логотип: \(scan.logo?.lastPathComponent ?? "нет")"
                 + (scan.problems.isEmpty ? "" : "; замечания: \(scan.problems.joined(separator: "; "))"))
    }

    private func rebuildCues() {
        let known = markers
        director.cues = Dictionary(uniqueKeysWithValues: songs.map {
            ($0.id, CueInfo(id: $0.id, duration: $0.duration, start: known[$0.id]))
        })
    }

    private func learned(_ id: Int, at position: Double) {
        guard songs.contains(where: { $0.id == id }) else { return }
        setMarker(id, position)
        Log.info("Метка: песня \(id) начинается в \(Timecode(realSeconds: position, rate: director.clock.rate).text)")
    }

    private func applyToEngine() {
        engine.fadeOut = settings.fadeOut
        engine.fadeIn = settings.fadeIn
        engine.crossfade = settings.crossfade
        engine.scale = settings.scale
        director.fadeOut = settings.fadeOut
        director.markerBaseNote = settings.markerBaseNote
    }

    private func settingsChanged(from old: Settings) {
        Store.save(settings)
        applyToEngine()
        output.choice = settings.display
        output.live = settings.live
        if settings.folderPath != old.folderPath {
            rescan()
        }
    }

    private func tick() {
        let now = HostTime.now
        let out = director.output(at: now)
        engine.update(out, next: director.nextCue(after: out), now: now)

        ticks += 1
        if ticks % 12 == 0 { updateStatus(out, now: now) }
        if ticks % 60 == 0 { Store.heartbeat() }
        if ticks % 300 == 0, case .song(let id, let position, let locked) = out {
            let drift = engine.activeSlot?.drift.map { "\(Int($0 * 1000)) мс" } ?? "—"
            Log.info("Песня \(id): \(String(format: "%.2f", position)) с, \(locked ? "по таймкоду" : "сама"), расхождение \(drift)")
        }
    }

    private func updateStatus(_ out: ShowOutput, now: Double) {
        var s = MonitorStatus()
        let connections = self.link.connections
        let age = director.lastMessageHost.map { now - $0 }
        s.linkOK = !connections.isEmpty || (age ?? 99) < 2
        var link: String
        if !self.link.hasSession {
            link = "No network MIDI session (create one in Audio MIDI Setup)"
        } else if connections.isEmpty {
            link = "Logic Mac not connected"
        } else {
            link = "Network: " + connections.map { "\($0.name) (\($0.state))" }.joined(separator: ", ")
        }
        if let age { link += age < 1 ? " · MIDI live" : " · last MIDI \(Self.ago(age)) ago" }
        s.link = link
        s.sources = midi.sourceNames.joined(separator: ", ")

        let clock = director.clock
        if let pos = clock.position(at: now) {
            s.mtcRunning = true
            s.timecode = Timecode(realSeconds: pos, rate: clock.rate).text
            s.rate = "\(clock.rate.label) fps"
        } else if let pos = director.lastKnownPosition {
            s.timecode = Timecode(realSeconds: pos, rate: clock.rate).text
            s.rate = "stopped"
        }

        switch out {
        case .black:
            s.screenText = "Blackout"
        case .logo:
            s.screenText = logoURL == nil ? "Logo (no file — black)" : "Logo"
            if let next = director.nextCue(after: out), let song = songs.first(where: { $0.id == next }) {
                s.detail = "Next: \(song.name)"
            }
        case .song(let id, let position, let locked):
            let name = songs.first { $0.id == id }?.name ?? "#\(id)"
            s.screenText = name
            var detail = "\(Self.clock(position)) · \(locked ? "locked to MTC" : "free run (no signal)")"
            if let drift = engine.activeSlot?.drift { detail += String(format: " · drift %+d ms", Int(drift * 1000)) }
            s.detail = detail
        }
        if manualBlack != director.manualBlack { manualBlack = director.manualBlack }
        if manualLogo != director.manualLogo { manualLogo = director.manualLogo }

        if !settings.live {
            s.outputText = "Off"
        } else if let target = output.currentTarget {
            s.outputText = "Live on \(target)"
        } else {
            s.outputText = "Waiting for display…"
        }
        if s != status { status = s }
    }

    /// Не гасить экран и не засыпать, пока программа работает
    private func preventDisplaySleep() {
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Live Video Sync: show output" as CFString, &sleepAssertion)
        Log.info(result == kIOReturnSuccess ? "Сон экрана запрещён" : "Не удалось запретить сон экрана (\(result))")
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }

    static func ago(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : seconds < 3600 ? "\(Int(seconds / 60)) min" : "\(Int(seconds / 3600)) h"
    }
}
