import CoreMIDI
import Foundation

/// MIDI-вход: слушает все источники (сетевую сессию с Logic, эмулятор), события отдаёт на главный поток.
final class MIDIInput {
    /// События с временем прихода (секунды HostTime)
    var onEvents: (([(MIDIEvent, Double)]) -> Void)?
    private(set) var sourceNames: [String] = []

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected = Set<MIDIUniqueID>()
    private var ignored = Set<MIDIUniqueID>()
    /// Только на потоке CoreMIDI
    private var parser = UMPParser()
    private static let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!

    func start() {
        var status = MIDIClientCreateWithBlock("LiveVideoSync" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectAllSources() }
            }
        }
        guard status == noErr else {
            Log.info("MIDI: не удалось создать клиента (\(status))")
            return
        }
        status = MIDIInputPortCreateWithProtocol(client, "Input" as CFString, ._1_0, &port) { [weak self] list, _ in
            self?.receive(list)
        }
        guard status == noErr else {
            Log.info("MIDI: не удалось создать порт (\(status))")
            return
        }
        connectAllSources()
    }

    /// Принимаем MIDI только из сетевого сеанса (Session 1) — в проекте Logic много дорожек,
    /// которые управляют пультом и приборами, и любые USB-устройства на этом Mac тоже не должны влиять на видео.
    /// Исключение — эмулятор Logic для проверок.
    static func isAllowed(_ source: MIDIEndpointRef, name: String) -> Bool {
        if name == "LVS Emulator" { return true }
        var entity = MIDIEntityRef()
        var device = MIDIDeviceRef()
        guard MIDIEndpointGetEntity(source, &entity) == noErr, MIDIEntityGetDevice(entity, &device) == noErr else { return false }
        var driver: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(device, kMIDIPropertyDriverOwner, &driver)
        let owner = (driver?.takeRetainedValue() as String?) ?? ""
        return owner == "com.apple.AppleMIDIRTPDriver" || owner == "com.apple.AppleMIDINetworkDriver"
    }

    private func connectAllSources() {
        var ids = Set<MIDIUniqueID>()
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uid)
            var cfName: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &cfName)
            let name = (cfName?.takeRetainedValue() as String?) ?? "?"
            guard Self.isAllowed(source, name: name) else {
                if !ignored.contains(uid) {
                    ignored.insert(uid)
                    Log.info("MIDI: источник «\(name)» не слушаем (не сетевой сеанс)")
                }
                continue
            }
            ids.insert(uid)
            names.append(name)
            if !connected.contains(uid) {
                let status = MIDIPortConnectSource(port, source, nil)
                Log.info("MIDI: подключён источник «\(name)» (\(status == noErr ? "ok" : "ошибка \(status)"))")
            }
        }
        for gone in connected.subtracting(ids) {
            Log.info("MIDI: источник \(gone) пропал")
        }
        connected = ids
        sourceNames = names
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>) {
        var events: [(MIDIEvent, Double)] = []
        for packet in list.unsafeSequence() {
            let stamp = packet.pointee.timeStamp
            let host = HostTime.seconds(stamp == 0 ? mach_absolute_time() : stamp)
            let count = Int(packet.pointee.wordCount)
            let base = UnsafeRawPointer(packet).advanced(by: Self.wordsOffset).assumingMemoryBound(to: UInt32.self)
            let words = Array(UnsafeBufferPointer(start: base, count: count))
            for event in parser.parse(words) {
                events.append((event, host))
            }
        }
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onEvents?(events)
        }
    }
}
