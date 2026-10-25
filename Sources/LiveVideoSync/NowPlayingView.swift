import AppKit
import SwiftUI

/// Слой превью в SwiftUI
private struct PreviewLayerView: NSViewRepresentable {
    let mirror: PreviewMirror

    final class View: NSView {
        let mirror: PreviewMirror
        init(mirror: PreviewMirror) {
            self.mirror = mirror
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
            mirror.rootLayer.removeFromSuperlayer()
            layer?.addSublayer(mirror.rootLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mirror.rootLayer.frame = bounds
            CATransaction.commit()
            mirror.sync()
        }
    }

    func makeNSView(context: Context) -> View { View(mirror: mirror) }
    func updateNSView(_ nsView: View, context: Context) {}
}

/// Превью = ровно то, что на экране сцены. На экране Show только для просмотра.
struct PreviewPanel: View {
    @ObservedObject var show: Show

    var body: some View {
        PreviewLayerView(mirror: show.preview)
            .aspectRatio(show.preview.aspect, contentMode: .fit)
            .overlay(alignment: .topLeading) { badges.padding(10) }
            .overlay(alignment: .bottomTrailing) { timeLabel.padding(10) }
            .overlay { dimmed }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    /// Вывод включён (даже если экран сцены пока не найден)
    private var isLive: Bool { show.outputState != .off }

    private var badges: some View {
        HStack(spacing: 8) {
            Text(isLive ? "LIVE" : "OFF")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(isLive ? Color.red : Color.gray.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
            Text(format)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    /// «Program · 1920×1080 · Fit height»
    private var format: String {
        let size = show.engine.rootLayer.bounds.size
        return "Program · \(Int(size.width))×\(Int(size.height)) · \(show.settings.scale.title)"
    }

    @ViewBuilder
    private var timeLabel: some View {
        let n = show.nowPlaying
        if n.number != nil, n.duration > 0, n.duration.isFinite {
            Text("\(Show.clock(n.position)) / \(Show.clock(n.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder
    private var dimmed: some View {
        switch show.outputState {
        case .off:
            overlayText("Output is off — the stage screen shows the wallpaper")
        case .waitingForDisplay(let name):
            overlayText("\(name) not connected — waiting for the display")
        case .live:
            EmptyView()
        }
    }

    private func overlayText(_ text: String) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            Text(text)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding()
        }
        .allowsHitTesting(false)
    }
}

/// Now Playing: что на экране, связь с Logic, ручное управление
struct NowPlayingPanel: View {
    @ObservedObject var show: Show

    var body: some View {
        let n = show.nowPlaying
        VStack(alignment: .leading, spacing: 8) {
            Text("NOW PLAYING")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(n.number.map { String(format: "%02d", $0) } ?? "—")
                .font(.system(size: 34, weight: .bold).monospacedDigit())
            Text(title(n))
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            StatusLine(color: modeColor(n), text: modeText(n))

            if n.number != nil, n.duration > 0, n.duration.isFinite {
                ProgressView(value: min(n.position, n.duration), total: n.duration)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 280)
                HStack {
                    Text(Show.minutes(n.position))
                    Spacer()
                    Text("−" + Show.minutes(n.duration - n.position))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: 280)
            }
            if let next = n.next {
                Text("Next: \(next)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Toggle("Logo", isOn: Binding(get: { show.manualLogo }, set: { _ in show.toggleLogo() }))
                    .help("Show the logo until Resume Sync (⌘G)")
                Toggle("Blackout", isOn: Binding(get: { show.manualBlack }, set: { _ in show.toggleBlackout() }))
                    .help("Black screen until Resume Sync (⌘B)")
                if show.isManual {
                    Button("Resume Sync", action: show.resumeSync)
                        .buttonStyle(.borderedProminent)
                        .help("Back to what the source plays now (⌘R)")
                } else {
                    Button("Resume Sync", action: show.resumeSync)
                        .disabled(true)
                }
            }
            .toggleStyle(.button)
            .padding(.top, 4)

            StatusLine(color: logicColor, text: show.logic.line)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func title(_ n: NowPlaying) -> String {
        switch n.mode {
        case .black: return "Blackout"
        case .logo: return show.settings.logoPath == nil ? "Logo (no file — black)" : "Logo"
        default: return n.title
        }
    }

    private func modeText(_ n: NowPlaying) -> String {
        switch n.mode {
        case .locked:
            return "Locked to MTC" + (n.drift.map { String(format: " · drift %+d ms", $0) } ?? "")
        case .free: return "Playing on its own — no timecode from the source"
        case .manual: return "Manual — plays to the end, then the logo"
        case .extras:
            let source = n.extrasSource ?? "Extras"
            return n.isImage ? "\(source) · image" : source
        case .logo: return show.manualLogo ? "Logo — held until Resume Sync" : "Waiting for a song from the source"
        case .black: return "Blackout — held until Resume Sync"
        }
    }

    private func modeColor(_ n: NowPlaying) -> Color {
        switch n.mode {
        case .locked: return .green
        case .free: return .orange
        case .manual, .black, .extras: return .blue
        case .logo: return show.manualLogo ? .blue : .secondary
        }
    }

    private var logicColor: Color {
        switch show.logic.state {
        case .connected: return .green
        case .waiting: return .orange
        case .lost, .noSession: return .red
        }
    }
}

/// Серый текст с цветной точкой
struct StatusLine: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }
}
