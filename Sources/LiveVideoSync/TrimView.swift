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

/// Лента кадров как в Фото: жёлтая рамка с широкими ручками — выбранный отрезок, белая линия — где сейчас
private struct FilmStrip: View {
    @ObservedObject var model: TrimModel
    private let handle: CGFloat = 12
    private let border: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - handle * 2, h = geo.size.height
            let x = { (t: Double) in handle + CGFloat(t / max(model.duration, 0.01)) * w }
            let time = { (px: CGFloat) in Double(min(max(0, px - handle), w) / w) * model.duration }
            let left = x(model.start), right = x(model.end)
            ZStack(alignment: .topLeading) {
                // Кадры
                HStack(spacing: 0) {
                    ForEach(model.thumbnails.indices, id: \.self) { i in
                        Image(decorative: model.thumbnails[i], scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: w / CGFloat(max(1, model.thumbnails.count)), height: h - border * 2)
                            .clipped()
                    }
                }
                .frame(width: w, height: h - border * 2, alignment: .leading)
                .background(Color.black)
                .offset(x: handle, y: border)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { model.seek(time($0.location.x + handle)) })

                // Вне отрезка — затемнено
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(0, left - handle), height: h - border * 2)
                    .offset(x: handle, y: border)
                    .allowsHitTesting(false)
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(0, handle + w - right), height: h - border * 2)
                    .offset(x: right, y: border)
                    .allowsHitTesting(false)

                // Жёлтая рамка: верх и низ
                Rectangle().fill(.yellow)
                    .frame(width: right - left + handle * 2, height: border)
                    .offset(x: left - handle)
                    .allowsHitTesting(false)
                Rectangle().fill(.yellow)
                    .frame(width: right - left + handle * 2, height: border)
                    .offset(x: left - handle, y: h - border)
                    .allowsHitTesting(false)

                handleView(left: true)
                    .frame(width: handle, height: h)
                    .offset(x: left - handle)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { model.setStart(time($0.location.x + handle / 2)) })
                handleView(left: false)
                    .frame(width: handle, height: h)
                    .offset(x: right)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { model.setEnd(time($0.location.x - handle / 2)) })

                // Где сейчас
                RoundedRectangle(cornerRadius: 1).fill(.white)
                    .frame(width: 2, height: h)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .offset(x: x(model.playhead) - 1)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: "strip")
        }
    }

    private func handleView(left: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: left ? 5 : 0, bottomLeadingRadius: left ? 5 : 0,
                               bottomTrailingRadius: left ? 0 : 5, topTrailingRadius: left ? 0 : 5)
            .fill(.yellow)
            .overlay(
                Image(systemName: left ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(.black.opacity(0.75))
            )
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
