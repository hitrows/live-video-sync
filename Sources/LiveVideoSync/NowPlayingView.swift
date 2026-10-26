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
                // Плавно: позицию досчитываем на каждом кадре экрана от последнего обновления
                TimelineView(.animation) { context in
                    let p = min(n.duration, max(0, n.position + context.date.timeIntervalSince(n.positionDate)))
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                Capsule().fill(Color.accentColor)
                                    .frame(width: max(4, geo.size.width * p / n.duration))
                            }
                        }
                        .frame(height: 6)
                        HStack {
                            Text(Show.minutes(p))
                            Spacer()
                            Text("−" + Show.minutes(n.duration - p))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 280)
            }
            if let next = n.next {
                Text("Next: \(next)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Как в плеере Apple: только значки; включённый — залитый и синий, название — в подсказке
            HStack(spacing: 20) {
                ControlIcon(symbol: "sparkles.rectangle.stack", isOn: show.manualLogo, label: "Logo",
                            help: "Logo — held until Resume Sync (⌘G)", action: show.toggleLogo)
                ControlIcon(symbol: "eye.slash", isOn: show.manualBlack, label: "Blackout",
                            help: "Blackout — black screen until Resume Sync (⌘B)", action: show.toggleBlackout)
                // Включён — экран идёт за источником; выключен — ручной режим. Нажать — вернуться к источнику
                ControlIcon(symbol: "link", isOn: !show.isManual, label: "Resume Sync",
                            help: show.isManual ? "Resume Sync — back to what the source plays now (⌘R)"
                                                : "Following the source",
                            action: show.resumeSync)
            }
            .padding(.vertical, 4)

            // Источник — меню, как выбор выхода звука в Музыке; точка снаружи (меню рисует только текст)
            HStack(spacing: 6) {
            Circle().fill(logicColor).frame(width: 8, height: 8)
            Menu {
                let visible = show.linkChoices.filter { show.link.isVisible($0.name) }
                if visible.isEmpty {
                    Text("No Macs with network MIDI found")
                }
                ForEach(visible, id: \.self) { mac in
                    Button {
                        show.connectLogic(mac)
                    } label: {
                        if mac.name == show.settings.logicMac?.name {
                            Label(mac.name, systemImage: "checkmark")
                        } else {
                            Text(mac.name)
                        }
                    }
                }
                if let saved = show.settings.logicMac, !visible.contains(where: { $0.name == saved.name }) {
                    Label("\(saved.name) — not on the network", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                }
                Divider()
                SettingsLink { Text("Sync Settings…") }
            } label: {
                Text(show.logic.line)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose the Mac that sends timecode")
            }
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

/// Кнопка-значок в стиле плеера Apple: без плашки, крупный значок, при наведении ярче
struct ControlIcon: View {
    let symbol: String
    let isOn: Bool
    let label: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn && NSImage(systemSymbolName: symbol + ".fill", accessibilityDescription: nil) != nil
                  ? symbol + ".fill" : symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary.opacity(hovering ? 1 : 0.75))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
