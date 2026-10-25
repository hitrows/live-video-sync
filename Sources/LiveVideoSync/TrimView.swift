import AVFoundation
import AppKit
import SwiftUI

/// Trim… — как в Фото и QuickTime: лента кадров с жёлтыми ручками начала и конца.
/// Файл не меняется — запоминаются точки начала и конца.
struct TrimView: View {
    let item: SetlistItem
    let number: Int
    let fullDuration: Double
    let onTrim: (_ start: Double, _ end: Double?) -> Void
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: TrimModel

    init(item: SetlistItem, number: Int, fullDuration: Double, onTrim: @escaping (Double, Double?) -> Void) {
        self.item = item
        self.number = number
        self.fullDuration = fullDuration
        self.onTrim = onTrim
        _model = StateObject(wrappedValue: TrimModel(url: item.url, duration: fullDuration,
                                                     start: item.trimStart, end: item.trimEnd ?? fullDuration))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Trim").font(.headline)
                Text(String(format: "%02d", number) + " \(item.displayName) · the file is not changed — only start and end points")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            PlayerLayerView(player: model.player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) {
                    Text(TrimModel.format(model.playhead))
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .padding(8)
                }

            HStack(spacing: 6) {
                Button(action: model.togglePlay) {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .keyboardShortcut(.space, modifiers: [])
                FilmStrip(model: model)
                    .frame(height: 44)
            }

            HStack(spacing: 24) {
                value("Start", TrimModel.format(model.start))
                value("End", TrimModel.format(model.end))
                value("Duration", "\(TrimModel.format(model.end - model.start)) of \(TrimModel.format(fullDuration))")
                Spacer()
            }

            HStack {
                Button("Reset to Full Length") { model.reset() }
                    .disabled(model.start == 0 && model.end == fullDuration)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Trim") {
                    let end = model.end >= fullDuration - 0.05 ? nil : model.end
                    onTrim(model.start < 0.05 ? 0 : model.start, end)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560)
        .onAppear { model.load() }
        .onDisappear { model.stop() }
    }

    private func value(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.body.monospacedDigit().weight(.semibold))
        }
    }
}

final class TrimModel: ObservableObject {
    let player = AVPlayer()
    let url: URL
    let duration: Double
    @Published var start: Double
    @Published var end: Double
    @Published var playhead: Double
    @Published var playing = false
    @Published var thumbnails: [CGImage] = []
    private var observer: Any?

    /// Самый короткий отрезок, с
    static let minLength = 1.0

    init(url: URL, duration: Double, start: Double, end: Double) {
        self.url = url
        self.duration = duration
        self.start = start
        self.end = end
        playhead = start
        player.isMuted = true
    }

    func load() {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        seek(start)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            guard let self, self.playing else { return }
            self.playhead = t.seconds
            if t.seconds >= self.end {
                self.player.pause()
                self.playing = false
                self.seek(self.start)
            }
        }
        Task { @MainActor in thumbnails = await Self.makeThumbnails(url: url, duration: duration, count: 14) }
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.replaceCurrentItem(with: nil)
    }

    func togglePlay() {
        if playing {
            player.pause()
            playing = false
        } else {
            if playhead < start || playhead >= end - 0.05 { seek(start) }
            player.play()
            playing = true
        }
    }

    func seek(_ t: Double) {
        playhead = min(max(0, t), duration)
        player.seek(to: CMTime(seconds: playhead, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setStart(_ t: Double) {
        start = min(max(0, t), end - Self.minLength)
        pause()
        seek(start)
    }

    func setEnd(_ t: Double) {
        end = max(min(duration, t), start + Self.minLength)
        pause()
        seek(end)
    }

    func reset() {
        start = 0
        end = duration
        pause()
        seek(0)
    }

    private func pause() {
        player.pause()
        playing = false
    }

    /// 3:38.0
    static func format(_ t: Double) -> String {
        let s = max(0, t)
        return "\(Int(s) / 60):" + String(format: "%04.1f", s.truncatingRemainder(dividingBy: 60))
    }

    static func makeThumbnails(url: URL, duration: Double, count: Int) async -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 90)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var images: [CGImage] = []
        for i in 0..<count {
            let t = duration * (Double(i) + 0.5) / Double(count)
            if let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                images.append(image)
            }
        }
        return images
    }
}

/// Лента кадров: жёлтая рамка с ручками — выбранный отрезок, белая линия — где сейчас
private struct FilmStrip: View {
    @ObservedObject var model: TrimModel

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = { (t: Double) in CGFloat(t / max(model.duration, 0.01)) * w }
            let time = { (px: CGFloat) in Double(min(max(0, px), w) / w) * model.duration }
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(model.thumbnails.indices, id: \.self) { i in
                        Image(decorative: model.thumbnails[i], scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: w / CGFloat(max(1, model.thumbnails.count)), height: geo.size.height)
                            .clipped()
                    }
                }
                .frame(width: w, height: geo.size.height, alignment: .leading)
                .background(.black)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { model.seek(time($0.location.x)) })

                // Вне отрезка — затемнено
                Rectangle().fill(.black.opacity(0.55))
                    .frame(width: x(model.start))
                    .allowsHitTesting(false)
                Rectangle().fill(.black.opacity(0.55))
                    .frame(width: max(0, w - x(model.end)))
                    .offset(x: x(model.end))
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.yellow, lineWidth: 3)
                    .frame(width: max(12, x(model.end) - x(model.start)))
                    .offset(x: x(model.start))
                    .allowsHitTesting(false)

                handle(left: true)
                    .offset(x: x(model.start))
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { model.setStart(time($0.location.x)) })
                handle(left: false)
                    .offset(x: x(model.end) - 10)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { model.setEnd(time($0.location.x)) })

                Rectangle().fill(.white)
                    .frame(width: 2, height: geo.size.height + 6)
                    .offset(x: x(model.playhead) - 1, y: -3)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: "strip")
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func handle(left: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(.yellow)
            Image(systemName: left ? "chevron.compact.left" : "chevron.compact.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
        }
        .frame(width: 10)
        .contentShape(Rectangle().inset(by: -6))
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
    }
}

/// AVPlayerLayer в SwiftUI (без системных кнопок плеера)
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
