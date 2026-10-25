import AVFoundation
import CoreMIDI
import Foundation

// Эмулятор Logic для проверки плеера без MacBook.
// Виртуальный MIDI-источник «LVS Emulator»: MTC 25 к/с, MMC Stop/Play, ноты-метки в начале песен, автостопы.
//
//   build/mtc-emulator <папка с видео>                 — интерактивно (help — список команд)
//   build/mtc-emulator <папка> --run "play; wait 5; stop"  — сценарий без участия человека

struct Song {
    let id: Int
    let name: String
    let start: Double
    let duration: Double
}

final class Emulator {
    let fps = 25.0
    let rate = MTCRate.fps25
    var markerBaseNote = 36
    var songs: [Song] = []
    var autostops: [Double] = []
    var sendMMC = true
    var linkUp = true
    /// Доля теряемых сообщений таймкода (имитация плохого Wi-Fi), 0…1
    var lossRate = 0.0

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var outPort = MIDIPortRef()
    /// Если задан — шлём в этот MIDI-выход (например, сетевой Session 1), а не в свой виртуальный источник
    private var destination: MIDIEndpointRef?
    private let queue = DispatchQueue(label: "emulator", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    // Транспорт (только на queue)
    private var playing = false
    private var position = 3600.0          // 01:00:00:00 — начало проекта
    private var playStartHost = 0.0
    private var playStartPosition = 0.0
    private var qfSent = 0
    private var lastPosition = 0.0

    init(destinationName: String?) {
        MIDIClientCreateWithBlock("LVS Emulator" as CFString, &client, nil)
        if let destinationName {
            MIDIOutputPortCreate(client, "Out" as CFString, &outPort)
            for i in 0..<MIDIGetNumberOfDestinations() {
                let d = MIDIGetDestination(i)
                var n: Unmanaged<CFString>?
                MIDIObjectGetStringProperty(d, kMIDIPropertyDisplayName, &n)
                let name = (n?.takeRetainedValue() as String?) ?? ""
                if name.localizedCaseInsensitiveContains(destinationName) {
                    destination = d
                    print("MIDI-выход: «\(name)»")
                    break
                }
            }
            if destination == nil { print("MIDI-выход «\(destinationName)» не найден"); exit(1) }
            return
        }
        let status = MIDISourceCreateWithProtocol(client, "LVS Emulator" as CFString, ._1_0, &source)
        if status != noErr { print("Не удалось создать MIDI-источник: \(status)"); exit(1) }
    }

    func loadProject(folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var list: [(Int, URL)] = []
        for url in files where ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
            let name = url.lastPathComponent
            if name.lowercased().contains("logo") { continue }
            if let id = Int(name.prefix { $0.isNumber }), id > 0 { list.append((id, url)) }
        }
        list.sort { $0.0 < $1.0 }
        // Проект как у группы: вступление 4 с, песни подряд с паузой 3 с,
        // после каждой четвёртой — автостоп (разговор)
        var t = 3604.0
        for (index, item) in list.enumerated() {
            let duration = Self.duration(of: item.1)
            let songLength = duration + 2       // песня длиннее видео на 2 с
            songs.append(Song(id: item.0, name: item.1.lastPathComponent, start: t, duration: songLength))
            t += songLength + 1
            if (index + 1) % 4 == 0 {
                autostops.append(t)
                t += 2
            }
            t += 2
        }
    }

    /// Синхронно и без async — эмулятор собирается и под Big Sur (там нет libswift_Concurrency)
    private static func duration(of url: URL) -> Double {
        AVURLAsset(url: url).duration.seconds
    }

    func printProject() {
        for s in songs {
            print("  песня \(s.id): \(Timecode(realSeconds: s.start, rate: rate).text) – \(Timecode(realSeconds: s.start + s.duration, rate: rate).text)  \(s.name)")
        }
        print("  автостопы: " + autostops.map { Timecode(realSeconds: $0, rate: rate).text }.joined(separator: ", "))
    }

    // MARK: - Отправка

    private func send(_ words: [UInt32]) {
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = words.withUnsafeBufferPointer { buffer in
            MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, mach_absolute_time(), buffer.count, buffer.baseAddress!)
        }
        if let destination {
            MIDISendEventList(outPort, destination, &list)
        } else {
            MIDIReceivedEventList(source, &list)
        }
    }

    private func sendQF(_ byte: UInt8) {
        guard linkUp, Double.random(in: 0..<1) >= lossRate else { return }
        send(UMPEncoder.quarterFrame(byte))
    }

    /// Испорченный полный код (как приходит через плохую сеть) — позиция на 10 минут дальше
    func glitch() {
        queue.sync {
            let bad = Timecode(realSeconds: position + 600, rate: rate)
            for b in MTCEncoder.quarterFrames(bad) { send(UMPEncoder.quarterFrame(b)) }
        }
    }
    private func sendSysex(_ p: [UInt8]) { if linkUp { send(UMPEncoder.sysex(p)) } }

    private func sendNote(_ note: Int) {
        guard linkUp else { return }
        send(UMPEncoder.noteOn(channel: 0, note: UInt8(note), velocity: 100))
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.send(UMPEncoder.noteOff(channel: 0, note: UInt8(note)))
        }
    }

    // MARK: - Транспорт

    func play() {
        let alreadyPlaying = queue.sync { playing }
        if alreadyPlaying { return }
        queue.sync {
            // Logic стартует с ровного кадра
            position = (position * fps).rounded(.down) / fps
            playing = true
            playStartHost = HostClock.now
            playStartPosition = position
            lastPosition = position - 0.0001
            qfSent = 0
            if sendMMC { sendSysex(MTCEncoder.mmc(0x02)) }
            startTimer()
        }
        log("▶ play с \(tc(position))")
    }

    func stop(reason: String = "") {
        queue.sync { stopLocked() }
        log("■ stop \(reason) на \(tc(currentPosition()))")
    }

    private func stopLocked() {
        guard playing else { return }
        playing = false
        timer?.cancel()
        timer = nil
        if sendMMC { sendSysex(MTCEncoder.mmc(0x01)) }
    }

    func locate(_ p: Double) {
        let wasPlaying = queue.sync { playing }
        if wasPlaying { queue.sync { stopLocked() } }
        queue.sync {
            position = p
            sendSysex(MTCEncoder.fullFrame(Timecode(realSeconds: p, rate: rate)))
        }
        log("⇥ goto \(tc(p))")
        if wasPlaying { play() }
    }

    func currentPosition() -> Double { queue.sync { position } }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(200))
        t.setEventHandler { [weak self] in self?.tickLocked() }
        t.resume()
        timer = t
    }

    private func tickLocked() {
        guard playing else { return }
        let elapsed = HostClock.now - playStartHost
        position = playStartPosition + elapsed

        // Кусочки MTC: 4 на кадр, группа из 8 описывает кадр, с которого началась
        let due = Int(elapsed * fps * 4) + 1
        while qfSent < due {
            let k = qfSent % 8
            let groupFrame = Int((playStartPosition * fps).rounded()) + (qfSent - k) / 4
            let tcode = Timecode(realSeconds: Double(groupFrame) / fps + 1e-6, rate: rate)
            sendQF(MTCEncoder.quarterFrames(tcode)[k])
            qfSent += 1
        }

        // Ноты-метки и автостопы, через которые прошёл курсор
        for s in songs where s.start >= lastPosition && s.start < position {
            sendNote(markerBaseNote + s.id - 1)
            log("♪ метка песни \(s.id) (\(s.name))")
        }
        for a in autostops where a >= lastPosition && a < position {
            position = a
            stopLocked()
            log("■ автостоп на \(tc(a))")
            break
        }
        lastPosition = position
    }

    private func tc(_ p: Double) -> String { Timecode(realSeconds: p, rate: rate).text }
}

enum HostClock {
    static var now: Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_absolute_time()) * Double(info.numer) / Double(info.denom) / 1e9
    }
}

let started = Date()
func log(_ s: String) {
    print(String(format: "[%7.2f] ", Date().timeIntervalSince(started)) + s)
    fflush(stdout)
}

// MARK: - Команды

let help = """
Команды:
  play | stop                — транспорт (stop шлёт MMC Stop, если mmc on)
  goto <N>                   — к началу песни N;  goto <чч:мм:сс:кк> — к таймкоду
  goto <N> +<сек>            — в середину песни N
  loss <проценты>            — терять часть таймкода (плохой Wi-Fi), loss 0 — без потерь
  glitch                     — отправить испорченный код (скачок на 10 минут)
  drop | restore             — обрыв связи (Logic играет, но ничего не доходит) / связь вернулась
  mmc on|off                 — слать ли MMC Stop/Play (проверить, что будет, если Logic не шлёт)
  wait <сек>                 — пауза (для сценариев)
  where | project | help | quit
"""


func execute(_ line: String) -> Bool {
    let parts = line.split(separator: " ").map(String.init)
    guard let cmd = parts.first?.lowercased() else { return true }
    switch cmd {
    case "play": emulator.play()
    case "stop": emulator.stop()
    case "goto":
        guard parts.count >= 2 else { print("goto <N> | goto <таймкод>"); break }
        var target: Double?
        if let n = Int(parts[1]), let song = emulator.songs.first(where: { $0.id == n }) {
            target = song.start
        } else {
            target = Timecode.parse(parts[1], rate: .fps25)
        }
        if parts.count >= 3, parts[2].hasPrefix("+"), let extra = Double(parts[2].dropFirst()) { target = target.map { $0 + extra } }
        if let target { emulator.locate(target) } else { print("Не понял, куда: \(parts[1])") }
    case "loss":
        let pct = parts.count >= 2 ? Double(parts[1]) ?? 0 : 0
        emulator.lossRate = max(0, min(100, pct)) / 100
        log("потери таймкода: \(Int(pct))%")
    case "glitch": emulator.glitch(); log("⚡ испорченный код")
    case "drop": emulator.linkUp = false; log("✂ связь оборвана")
    case "restore": emulator.linkUp = true; log("↺ связь вернулась")
    case "mmc":
        emulator.sendMMC = parts.count < 2 || parts[1] != "off"
        log("MMC \(emulator.sendMMC ? "вкл" : "выкл")")
    case "wait":
        let seconds = parts.count >= 2 ? Double(parts[1]) ?? 1 : 1
        Thread.sleep(forTimeInterval: seconds)
    case "where": log("позиция \(Timecode(realSeconds: emulator.currentPosition(), rate: .fps25).text)")
    case "project": emulator.printProject()
    case "help": print(help)
    case "quit", "exit": return false
    default: print("Неизвестная команда: \(cmd). help — список")
    }
    return true
}

var args = Array(CommandLine.arguments.dropFirst())
var script: String?
if let i = args.firstIndex(of: "--run"), i + 1 < args.count {
    script = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
var destinationName: String?
if let i = args.firstIndex(of: "--dest"), i + 1 < args.count {
    destinationName = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
let emulator = Emulator(destinationName: destinationName)
if let i = args.firstIndex(of: "--base"), i + 1 < args.count, let n = Int(args[i + 1]) {
    emulator.markerBaseNote = n
    args.removeSubrange(i...(i + 1))
}
guard let folder = args.first else {
    print("Использование: mtc-emulator <папка с видео> [--run \"команды; через; точку с запятой\"] [--base 36] [--dest \"Session 1\"]")
    exit(1)
}
emulator.loadProject(folder: URL(fileURLWithPath: folder))
print("Эмулятор Logic: MIDI-источник «LVS Emulator», MTC 25 к/с. Проект:")
emulator.printProject()

if let script {
    Thread.sleep(forTimeInterval: 1)    // плеер успевает подключиться к новому источнику
    for command in script.split(separator: ";") {
        let c = command.trimmingCharacters(in: .whitespaces)
        if !c.isEmpty, !execute(c) { break }
    }
    emulator.stop(reason: "(конец сценария)")
    exit(0)
}

print(help)
while let line = readLine() {
    if !execute(line.trimmingCharacters(in: .whitespaces)) { break }
}
