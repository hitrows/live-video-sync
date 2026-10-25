import AVFoundation
import Foundation

/// Что известно о файле песни или Extras
struct MediaInfo: Equatable {
    var duration: Double = 0
    var isImage = false
    var hasAudio = false
    var size: CGSize = .zero
    /// Файла нет на месте (переместили, отключён диск)
    var missing = false
    /// Файл есть, но не открывается как видео
    var error: String?
    /// Не мешают играть, но старт с середины или подстройка будут медленными
    var warnings: [String] = []

    var playable: Bool { !missing && error == nil && (isImage || duration > 0) }
    /// Текст для подсказки у значка ⚠︎
    var problem: String? {
        if missing { return "The original file could not be found." }
        if let error { return error }
        return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    }
}

enum Library {
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff"]

    static func isMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return videoExtensions.contains(ext) || imageExtensions.contains(ext)
    }

    static func inspect(_ url: URL) async -> MediaInfo {
        var info = MediaInfo()
        guard FileManager.default.fileExists(atPath: url.path) else {
            info.missing = true
            return info
        }
        if imageExtensions.contains(url.pathExtension.lowercased()) {
            info.isImage = true
            return info
        }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard duration.isFinite, duration > 0, let track = tracks.first else {
                info.error = "Not a video file or the file is empty."
                return info
            }
            info.duration = duration
            info.hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
            if let size = try? await track.load(.naturalSize) { info.size = size }
            info.warnings = await check(track, duration: duration)
        } catch {
            info.error = "The file can’t be opened: \(error.localizedDescription)"
        }
        return info
    }

    /// Старый формат: папка «NN_название.mp4» + файл со словом «logo». Для переноса в сет.
    static func scanLegacyFolder(_ folder: URL) -> (songs: [(number: Int, url: URL)], logo: URL?) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles])) ?? [])
            .filter { videoExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var logo: URL?
        var byNumber: [Int: URL] = [:]
        for url in files {
            let name = url.lastPathComponent
            if name.lowercased().contains("logo") {
                if logo == nil { logo = url }
                continue
            }
            if let n = Int(name.prefix { $0.isNumber }), n > 0, byNumber[n] == nil { byNumber[n] = url }
        }
        return (byNumber.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, logo)
    }

    /// Предупреждения о файлах, с которыми старт с середины и подстройка будут медленными
    static func check(_ track: AVAssetTrack, duration: Double) async -> [String] {
        var warnings: [String] = []
        if let formats = try? await track.load(.formatDescriptions), let format = formats.first {
            let codec = CMFormatDescriptionGetMediaSubType(format)
            let ok: Set<FourCharCode> = [fourCC("avc1"), fourCC("hvc1"), fourCC("hev1"),
                                         fourCC("apcn"), fourCC("apch"), fourCC("apcs"), fourCC("apco"), fourCC("ap4h")]
            if !ok.contains(codec) { warnings.append("Codec \(fourCCString(codec)) — H.264 is safer.") }
        }
        if let size = try? await track.load(.naturalSize), size.width * size.height > 3840 * 2160 {
            warnings.append("\(Int(size.width))×\(Int(size.height)) is heavy — 1920×1080 or less is safer.")
        }
        if let gap = keyframeGap(track, duration: duration), gap > 2.0 {
            warnings.append(String(format: "A keyframe only every %.1f s — starting mid-song will be slow. Re-export with a keyframe every 1 s.", gap))
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
