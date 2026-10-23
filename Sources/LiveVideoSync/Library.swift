import AVFoundation
import Foundation

struct VideoFile: Identifiable, Equatable {
    /// Номер песни из начала имени файла: «03_Song.mp4» → 3
    let id: Int
    let url: URL
    let duration: Double
    var name: String { url.lastPathComponent }
}

struct LibraryScan {
    var songs: [VideoFile] = []
    var logo: URL?
    var problems: [String] = []
}

/// Папка с видео: «NN_название.mp4» — песни, файл со словом «logo» в имени — логотип
enum Library {
    static let extensions: Set<String> = ["mp4", "mov", "m4v"]

    static func scan(folder: URL) async -> LibraryScan {
        var result = LibraryScan()
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles])
                .filter { extensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            result.problems.append("Папка не читается: \(error.localizedDescription)")
            return result
        }

        var byId: [Int: VideoFile] = [:]
        for url in files {
            let name = url.lastPathComponent
            if name.lowercased().contains("logo") {
                if result.logo == nil { result.logo = url } else { result.problems.append("Второй логотип пропущен: \(name)") }
                continue
            }
            let digits = name.prefix { $0.isNumber }
            guard let id = Int(digits), id > 0 else {
                result.problems.append("Нет номера в начале имени: \(name)")
                continue
            }
            if let existing = byId[id] {
                result.problems.append("Номер \(id) повторяется: \(existing.name) и \(name)")
                continue
            }
            let asset = AVURLAsset(url: url)
            do {
                let duration = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard duration.isFinite, duration > 0, !tracks.isEmpty else {
                    result.problems.append("Не видео или пустой файл: \(name)")
                    continue
                }
                byId[id] = VideoFile(id: id, url: url, duration: duration)
                result.problems += await check(tracks[0], duration: duration).map { "\(name): \($0)" }
            } catch {
                result.problems.append("Файл не открывается: \(name) — \(error.localizedDescription)")
            }
        }
        if let logo = result.logo, let track = try? await AVURLAsset(url: logo).loadTracks(withMediaType: .video).first {
            let d = (try? await AVURLAsset(url: logo).load(.duration).seconds) ?? 0
            result.problems += await check(track, duration: d).map { "\(logo.lastPathComponent): \($0)" }
        }
        result.songs = byId.values.sorted { $0.id < $1.id }
        if result.logo == nil { result.problems.append("Нет файла логотипа (имя должно содержать «logo»)") }
        return result
    }

    /// Предупреждения о файлах, с которыми старт с середины и подстройка будут медленными
    static func check(_ track: AVAssetTrack, duration: Double) async -> [String] {
        var warnings: [String] = []
        if let formats = try? await track.load(.formatDescriptions), let format = formats.first {
            let codec = CMFormatDescriptionGetMediaSubType(format)
            let ok: Set<FourCharCode> = [fourCC("avc1"), fourCC("hvc1"), fourCC("hev1"),
                                         fourCC("apcn"), fourCC("apch"), fourCC("apcs"), fourCC("apco"), fourCC("ap4h")]
            if !ok.contains(codec) { warnings.append("кодек \(fourCCString(codec)) — лучше H.264") }
        }
        if let size = try? await track.load(.naturalSize), size.width * size.height > 3840 * 2160 {
            warnings.append("разрешение \(Int(size.width))×\(Int(size.height)) — тяжело, лучше 1920×1080 или меньше")
        }
        if let gap = keyframeGap(track, duration: duration), gap > 2.0 {
            warnings.append(String(format: "ключевой кадр раз в %.1f с — старт с середины песни будет медленным, лучше пережать с ключевым кадром раз в 1 с", gap))
        }
        return warnings
    }

    /// Самый большой промежуток между ключевыми кадрами (по индексу файла, видео не декодируется)
    static func keyframeGap(_ track: AVAssetTrack, duration: Double) -> Double? {
        guard track.canProvideSampleCursors, let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { return nil }
        var lastSync: Double?
        var maxGap = 0.0
        var count = 0
        repeat {
            if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
                let t = cursor.presentationTimeStamp.seconds
                if let last = lastSync { maxGap = max(maxGap, t - last) }
                lastSync = t
            }
            count += 1
        } while cursor.stepInDecodeOrder(byCount: 1) == 1 && count < 200_000
        guard let last = lastSync else { return duration }
        return max(maxGap, duration - last)
    }

    private static func fourCC(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    private static func fourCCString(_ c: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((c >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
    }
}
