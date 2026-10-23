import AppKit
import SwiftUI

/// Окно управления: настройка дома или на репетиции. Во время шоу его никто не трогает.
struct ControlView: View {
    @ObservedObject var show: Show
    @State private var linkSelection: LinkTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            monitor
            Divider()
            outputSection
            linkSection
            folderSection
            transitionSection
            songsTable
            footer
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 620)
    }

    // MARK: - Монитор

    private var monitor: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(show.status.timecode)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .foregroundColor(show.status.mtcRunning ? .green : .secondary)
                Text(show.status.mtcRunning ? "MTC \(show.status.rate)" : "MTC \(show.status.rate.isEmpty ? "—" : show.status.rate)")
                    .font(.caption).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(show.status.screenText).font(.title3.weight(.semibold)).lineLimit(1)
                Text(show.status.detail).font(.callout.monospacedDigit()).foregroundColor(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(show.status.linkOK ? Color.green : Color.red).frame(width: 9, height: 9)
                    Text(show.status.link).font(.callout).lineLimit(1)
                }
            }
            Spacer()
            Button(action: HelpWindow.show) {
                Image(systemName: "questionmark.circle").font(.system(size: 22))
            }
            .buttonStyle(.borderless)
            .help("Setup and troubleshooting")
            VStack(alignment: .trailing, spacing: 6) {
                Button(action: show.toggleLive) {
                    Text(show.settings.live ? "■  STOP OUTPUT" : "●  GO LIVE")
                        .font(.headline)
                        .frame(width: 170, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(show.settings.live ? .red : .accentColor)
                Text(show.status.outputText).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Экран

    private var outputSection: some View {
        HStack(spacing: 10) {
            Text("Display").frame(width: 90, alignment: .leading)
            Picker("", selection: $show.settings.display) {
                Text("First external display").tag(DisplayChoice.firstExternal)
                ForEach(displayRefs, id: \.self) { ref in
                    Text(ref.name + (connected(ref) ? "" : " (not connected)")).tag(DisplayChoice.specific(ref))
                }
                Text("Window (test)").tag(DisplayChoice.window)
            }
            .labelsHidden()
            .frame(width: 300)
            Picker("", selection: Binding(get: { show.settings.scale }, set: { show.setScale($0) })) {
                ForEach(ScaleMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            Spacer()
            Toggle("Blackout", isOn: Binding(get: { show.manualBlack }, set: { _ in show.toggleBlackout() }))
                .toggleStyle(.button)
            Toggle("Logo", isOn: Binding(get: { show.manualLogo }, set: { _ in show.toggleLogo() }))
                .toggleStyle(.button)
        }
    }

    private var displayRefs: [DisplayRef] {
        var refs = NSScreen.screens.map(OutputController.ref(for:))
        if case .specific(let saved) = show.settings.display, !refs.contains(saved) { refs.append(saved) }
        return refs
    }

    private func connected(_ ref: DisplayRef) -> Bool {
        NSScreen.screens.contains { OutputController.ref(for: $0) == ref }
    }

    // MARK: - Сетевой MIDI

    private var linkSection: some View {
        HStack(spacing: 10) {
            Text("Logic Mac").frame(width: 90, alignment: .leading)
            Picker("", selection: $linkSelection) {
                if show.linkChoices.isEmpty { Text("Searching the network…").tag(LinkTarget?.none) }
                ForEach(show.linkChoices, id: \.self) { target in
                    Text(target.name).tag(Optional(target))
                }
            }
            .labelsHidden()
            .frame(width: 300)
            .disabled(show.linkChoices.isEmpty)
            Button("Connect") { if let t = linkSelection ?? show.linkChoices.first { show.connectLogic(t) } }
                .disabled(show.linkChoices.isEmpty)
            Button("Disconnect", action: show.disconnectLogic)
                .disabled(show.settings.logicMac == nil && show.link.connections.isEmpty)
            Spacer()
            if let saved = show.settings.logicMac {
                Text("auto-reconnect: \(saved.name)").font(.caption).foregroundColor(.secondary)
            }
        }
        .onAppear { linkSelection = show.settings.logicMac }
    }

    // MARK: - Папка

    private var folderSection: some View {
        HStack(spacing: 10) {
            Text("Videos").frame(width: 90, alignment: .leading)
            Text(show.settings.folderPath ?? "Not chosen")
                .lineLimit(1).truncationMode(.middle)
                .foregroundColor(show.settings.folderPath == nil ? .secondary : .primary)
            Spacer()
            Button("Choose…", action: show.chooseFolder)
            Button("Rescan", action: show.rescan).disabled(show.settings.folderPath == nil || show.scanning)
        }
    }

    // MARK: - Переходы

    private var transitionSection: some View {
        HStack(spacing: 10) {
            Text("Transition").frame(width: 90, alignment: .leading)
            Picker("", selection: $show.settings.crossfade) {
                Text("Fade through black").tag(false)
                Text("Crossfade").tag(true)
            }
            .labelsHidden().frame(width: 180)
            Text("Fade out")
            secondsField($show.settings.fadeOut)
            Text("Fade in")
            secondsField($show.settings.fadeIn)
            Spacer()
            Text("First song marker")
            Picker("", selection: $show.settings.markerBaseNote) {
                ForEach(0..<116, id: \.self) { n in Text(Self.noteName(n)).tag(n) }
            }
            .labelsHidden().frame(width: 80)
        }
    }

    private func secondsField(_ value: Binding<Double>) -> some View {
        HStack(spacing: 2) {
            TextField("", value: value, format: .number.precision(.fractionLength(1)))
                .frame(width: 44).multilineTextAlignment(.trailing)
            Stepper("", value: value, in: 0...5, step: 0.1).labelsHidden()
            Text("s").foregroundColor(.secondary)
        }
    }

    // MARK: - Песни

    private var songsTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Table(show.songs) {
                TableColumn("#") { Text("\($0.id)").monospacedDigit() }.width(30)
                TableColumn("File") { Text($0.name).lineLimit(1) }
                TableColumn("Length") { Text(Show.clock($0.duration)).monospacedDigit() }.width(70)
                TableColumn("Marker") { song in
                    Text(Self.noteName(show.settings.markerBaseNote + song.id - 1)).monospacedDigit()
                }.width(60)
                TableColumn("Starts in Logic") { song in
                    if let start = show.markers[song.id] {
                        HStack {
                            Text(Timecode(realSeconds: start, rate: show.director.clock.rate).text).monospacedDigit()
                            Button("Reset") { show.resetMarker(song) }.buttonStyle(.borderless).font(.caption)
                        }
                    } else {
                        Text("not learned yet").foregroundColor(.secondary)
                    }
                }.width(170)
            }
            HStack {
                Text("Logo: " + (show.logoURL?.lastPathComponent ?? "missing"))
                    .foregroundColor(show.logoURL == nil ? .orange : .secondary)
                Spacer()
                Button("Reset all markers", action: show.resetMarkers).disabled(show.markers.isEmpty)
            }
            ForEach(show.problems, id: \.self) { problem in
                Text("⚠︎ " + problem).font(.callout).foregroundColor(.orange)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Markers: a note at the start of each song on a MIDI track sent to the network session — the player learns where each song begins.")
            Text("MIDI sources: \(show.status.sources.isEmpty ? "none" : show.status.sources)   ·   Log: \(Log.url.path)")
        }
        .font(.caption).foregroundColor(.secondary)
    }

    /// Имена нот как в Logic: 36 = C1, 60 = C3
    static func noteName(_ n: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        guard (0...127).contains(n) else { return "—" }
        return "\(names[n % 12])\(n / 12 - 2)"
    }
}
