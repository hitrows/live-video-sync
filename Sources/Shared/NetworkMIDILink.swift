import CoreMIDI
import Foundation

/// Сетевой MIDI (RTP-MIDI — то же, что Audio MIDI Setup → Network).
/// MIDINetworkSession на macOS ничего не делает (это API для iOS), поэтому работаем с драйвером напрямую:
/// сеанс — сущность устройства «Network», его настройки — словарь `apple.midirtp.session`:
///   dns-sd-name — имя в сети, flags бит 0 — включён, join-policy 2 — подключаться может любой,
///   peers — текущие подключения [{name, address "хост:порт", state}], persistent-peers — запомненные.
/// Запись словаря применяется драйвером сразу. Создать новый сеанс так нельзя — только в Audio MIDI Setup («+»).
/// Сеанс работает, пока на Mac запущена хоть одна MIDI-программа (иначе системная MIDI-служба выключается).
/// Общий код для MIDI Link (Big Sur) и плеера (macOS 15) — только API macOS 11.
final class NetworkMIDILink: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Peer: Equatable {
        let name: String
        /// Адрес как у Audio MIDI Setup — по имени сервиса Bonjour: «\tИмя Mac\tlocal.».
        /// Драйвер сам находит Mac по имени; «хост.local:порт» между ноутбуками не устанавливался
        let address: String
        /// «IP:порт» — запасной вариант, если имя .local в сети не находится (изоляция клиентов, мультикаст)
        var ip: String?
    }

    struct Connection: Equatable {
        let name: String
        let address: String
        /// connected / running / … — как пишет драйвер
        let state: String
    }

    /// Найденные в сети Mac (кроме этого)
    private(set) var peers: [Peer] = []
    var onChange: (() -> Void)?
    var log: (String) -> Void = { _ in }
    /// С кем держать связь: пропала — подключиться снова (пока программа запущена)
    var keepConnectedTo: Peer?

    private var client = MIDIClientRef()
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var timer: Timer?
    private var lastStatus = ""
    /// Попытки подключиться к keepConnectedTo: чётные — по имени, нечётные — по IP
    private var attempts = 0
    /// Раньше этого не пробуем снова: рукопожатию нужно время, а каждая запись настроек сбрасывает подключения сеанса
    private var nextAttempt = Date.distantPast
    static let retryInterval: TimeInterval = 10
    /// Драйвер иногда на пару секунд «теряет» живое подключение из списка — переподключаемся, только если его нет столько секунд подряд
    static let missingGrace: TimeInterval = 30
    private var lastSeenConnected = Date.distantPast
    /// С какого момента подключение висит в непонятном состоянии
    private var stuckSince: [String: Date] = [:]
    private static let goodStates: Set<String> = ["connected", "running"]
    private static let key = "apple.midirtp.session" as CFString

    func start() {
        MIDIClientCreateWithBlock("NetworkMIDILink" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgPropertyChanged || notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.onChange?() }
            }
        }
        prepareSession()
        browser.delegate = self
        browser.searchForServices(ofType: "_apple-midi._udp.", inDomain: "local.")
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.maintain() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Драйвер

    private var networkDevice: MIDIDeviceRef? {
        for i in 0..<MIDIGetNumberOfDevices() {
            let device = MIDIGetDevice(i)
            var driver: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(device, kMIDIPropertyDriverOwner, &driver)
            var ump: Int32 = 0
            MIDIObjectGetIntegerProperty(device, "ump enabled" as CFString, &ump)
            let owner = (driver?.takeRetainedValue() as String?) ?? ""
            // Классический сеанс (MIDI 1.0): AppleMIDIRTPDriver (Big Sur) или AppleMIDINetworkDriver без UMP (новые macOS)
            if (owner == "com.apple.AppleMIDIRTPDriver" || owner == "com.apple.AppleMIDINetworkDriver") && ump == 0 {
                return device
            }
        }
        return nil
    }

    /// Сеанс этого Mac (первый) — nil, если ни одного не создано
    private var sessionEntity: MIDIEntityRef? {
        guard let device = networkDevice, MIDIDeviceGetNumberOfEntities(device) > 0 else { return nil }
        return MIDIDeviceGetEntity(device, 0)
    }

    var hasSession: Bool { sessionEntity != nil }

    /// Имя сеанса (как его видно в MIDI-программах, например «Session 1»)
    var sessionName: String {
        guard let entity = sessionEntity else { return "" }
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(entity, kMIDIPropertyName, &name)
        return (name?.takeRetainedValue() as String?) ?? ""
    }

    private func readSettings() -> NSMutableDictionary? {
        guard let entity = sessionEntity else { return nil }
        var dict: Unmanaged<CFDictionary>?
        guard MIDIObjectGetDictionaryProperty(entity, Self.key, &dict) == noErr, let d = dict?.takeRetainedValue() else { return nil }
        return NSMutableDictionary(dictionary: d)
    }

    @discardableResult
    private func writeSettings(_ settings: NSDictionary) -> Bool {
        guard let entity = sessionEntity else { return false }
        let status = MIDIObjectSetDictionaryProperty(entity, Self.key, settings)
        if status != noErr { log("Сеанс: не удалось записать настройки (\(status))") }
        return status == noErr
    }

    /// Имя этого Mac в сети
    var ownName: String { (readSettings()?["dns-sd-name"] as? String) ?? "" }

    /// Включить сеанс, открыть для всех, дать имя (без имени Mac не виден в сети).
    /// Перезапись настроек заодно «будит» драйвер — без неё сеанс иногда не объявляется в сети.
    func prepareSession() {
        guard let settings = readSettings() else {
            log("Сетевого MIDI-сеанса нет — его нужно один раз создать в Audio MIDI Setup")
            return
        }
        let flags = (settings["flags"] as? Int) ?? 0
        settings["flags"] = flags | 1
        settings["join-policy"] = 2
        if ((settings["dns-sd-name"] as? String) ?? "").isEmpty {
            settings["dns-sd-name"] = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        }
        if writeSettings(settings) {
            log("Сетевой MIDI-сеанс «\(sessionName)» включён, имя в сети «\(settings["dns-sd-name"] ?? "")», вход открыт всем")
        }
    }

    var connections: [Connection] {
        guard let list = readSettings()?["peers"] as? [NSDictionary] else { return [] }
        return list.map {
            Connection(name: ($0["name"] as? String) ?? "?", address: ($0["address"] as? String) ?? "",
                       state: ($0["state"] as? String) ?? "")
        }
    }

    /// Виден ли этот Mac в сети прямо сейчас (объявляет сетевой MIDI по Bonjour)
    func isVisible(_ name: String) -> Bool {
        services.contains { $0.name == name }
    }

    /// Подключён ли (или подключается) этот Mac
    func isConnected(_ peer: Peer) -> Bool {
        connections.contains { c in
            c.name == peer.name || c.address == peer.address || (peer.ip != nil && c.address == peer.ip)
                || (peer.ip.map { c.name == $0.components(separatedBy: ":")[0] } ?? false)
        }
    }

    /// byIP — подключаться по запомненному IP вместо имени .local
    func connect(_ peer: Peer, byIP: Bool = false) {
        guard let settings = readSettings() else { return }
        nextAttempt = Date().addingTimeInterval(Self.retryInterval)
        let address = byIP ? (peer.ip ?? peer.address) : peer.address
        var list = (settings["peers"] as? [NSDictionary]) ?? []
        if !list.contains(where: { ($0["address"] as? String) == address }) {
            list.append(["name": peer.name, "address": address])
        }
        settings["peers"] = list
        // Запомнить: так видно в Audio MIDI Setup и после перезагрузки
        var persistent = (settings["persistent-peers"] as? [NSDictionary]) ?? []
        if !persistent.contains(where: { ($0["name"] as? String) == peer.name }) {
            persistent.append(["name": peer.name, "address": address])
        }
        settings["persistent-peers"] = persistent
        log("Подключение к «\(peer.name)» (\(address)): \(writeSettings(settings) ? "ok" : "ошибка")")
        onChange?()
    }

    /// Убрать одно подключение (зависшее)
    private func remove(address: String) {
        guard let settings = readSettings() else { return }
        let list = ((settings["peers"] as? [NSDictionary]) ?? []).filter { ($0["address"] as? String) != address }
        settings["peers"] = list
        writeSettings(settings)
    }

    func disconnectAll() {
        guard let settings = readSettings() else { return }
        settings["peers"] = []
        settings["persistent-peers"] = []
        log("Отключено всё: \(writeSettings(settings) ? "ok" : "ошибка")")
        onChange?()
    }

    private func maintain() {
        let status = connections.map { "\($0.name) [\($0.address)] \($0.state.isEmpty ? "—" : $0.state)" }.joined(separator: ", ")
        if status != lastStatus {
            log("Подключения: \(status.isEmpty ? "нет" : status)")
            lastStatus = status
        }
        // Подключение долго в непонятном состоянии (адрес не отвечает) — убрать, дальше попробуем другой адрес
        let now = Date()
        // Только своё подключение к keepConnectedTo — чужие (другой плеер, входящие) не трогаем никогда
        let mine: (Connection) -> Bool = { [keepConnectedTo] c in
            guard let t = keepConnectedTo else { return false }
            return c.address == t.address || (t.ip != nil && c.address == t.ip)
        }
        for c in connections where mine(c) && !Self.goodStates.contains(c.state) && !c.state.isEmpty {
            let since = stuckSince[c.address] ?? now
            stuckSince[c.address] = since
            if now.timeIntervalSince(since) > 10 {
                log("Подключение к «\(c.name)» (\(c.address)) не установилось (\(c.state)) — убираю")
                remove(address: c.address)
                stuckSince[c.address] = nil
            }
        }
        let current = connections
        stuckSince = stuckSince.filter { key, _ in current.contains { $0.address == key } }

        if let target = keepConnectedTo, isConnected(target) { lastSeenConnected = now }
        if let target = keepConnectedTo, !isConnected(target), now >= nextAttempt,
           now.timeIntervalSince(lastSeenConnected) > Self.missingGrace {
            nextAttempt = now.addingTimeInterval(Self.retryInterval)
            // Адрес мог поменяться — берём свежий из сети, если Mac виден; IP помним из прошлого раза
            var fresh = peers.first { $0.name == target.name } ?? target
            if fresh.ip == nil { fresh.ip = target.ip }
            let byIP = attempts % 2 == 1 && fresh.ip != nil
            attempts += 1
            log("Связи с «\(target.name)» нет — подключаюсь \(byIP ? "по IP" : "по имени")")
            connect(fresh, byIP: byIP)
        } else if let target = keepConnectedTo, isConnected(target) {
            attempts = 0
            nextAttempt = now.addingTimeInterval(Self.retryInterval)
        }
        onChange?()
    }

    // MARK: - Поиск в сети (Bonjour)

    /// Адрес сервиса в формате драйвера: «\tИмя\tlocal.»
    static func serviceAddress(_ name: String, domain: String = "local.") -> String {
        "\t\(name)\t\(domain.isEmpty ? "local." : domain)"
    }

    /// IPv4-адрес из ответа Bonjour
    private static func ipv4(_ service: NetService) -> String? {
        for data in service.addresses ?? [] {
            let ip: String? = data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, raw.count >= MemoryLayout<sockaddr_in>.size,
                      base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var addr = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: buffer)
            }
            if let ip { return ip }
        }
        return nil
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 10)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        // Из списка не убираем: объявление в сети мигает, а адрес остаётся рабочим
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostName = sender.hostName, sender.port > 0 else { return }
        let host = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        let ownHost = ProcessInfo.processInfo.hostName.lowercased()
        if host.lowercased() == ownHost || sender.name == ownName { return }
        let peer = Peer(name: sender.name, address: Self.serviceAddress(sender.name, domain: sender.domain),
                        ip: Self.ipv4(sender).map { "\($0):\(sender.port)" })
        if let i = peers.firstIndex(where: { $0.name == peer.name }) {
            if peers[i] == peer { return }
            peers[i] = peer
        } else {
            peers.append(peer)
            peers.sort { $0.name < $1.name }
            log("Найден в сети: «\(peer.name)» (\(peer.address))")
        }
        onChange?()
    }
}
