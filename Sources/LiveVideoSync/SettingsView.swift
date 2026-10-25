import AppKit
import SwiftUI

/// Live Video Sync → Settings… (⌘,): General / Logic / Output / Help
struct SettingsView: View {
    @ObservedObject var show: Show

    var body: some View {
        TabView {
            GeneralSettings(show: show)
                .tabItem { Label("General", systemImage: "gearshape") }
            LogicSettings(show: show)
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            OutputSettings(show: show)
                .tabItem { Label("Output", systemImage: "display") }
            HelpSettings()
                .tabItem { Label("Help", systemImage: "questionmark.circle") }
        }
        .frame(width: 520)
    }
}

/// Строка с подписью и пояснением мелким текстом
private struct RowLabel: View {
    let title: String
    var detail: String?

    init(_ title: String, _ detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SecondsField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 0.1

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                      format: .number.precision(.fractionLength(step < 1 ? 1 : 0)))
                .multilineTextAlignment(.trailing)
                .frame(width: 50)
                .labelsHidden()
            Text("s").foregroundStyle(.secondary)
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var show: Show
    @State private var audioOutputs = AudioDevices.outputs()

    var body: some View {
        Form {
            Section("Transitions") {
                LabeledContent("Style") {
                    Picker("Style", selection: $show.settings.transition) {
                        ForEach(Transition.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                LabeledContent {
                    SecondsField(value: $show.settings.transitionDuration, range: 0...5)
                        .disabled(show.settings.transition == .cut)
                } label: {
                    RowLabel("Duration", "Fade out and fade in")
                }
            }
            Section("Markers") {
                Picker(selection: $show.settings.markerBaseNote) {
                    ForEach(0..<116, id: \.self) { Text(Show.noteName($0)).tag($0) }
                } label: {
                    RowLabel("First song marker",
                             "Song 1 = \(Show.noteName(show.settings.markerBaseNote)), song 2 = \(Show.noteName(show.settings.markerBaseNote + 1)) … (position in the setlist)")
                }
            }
            Section("Extras") {
                LabeledContent {
                    SecondsField(value: $show.settings.extrasImageDuration, range: 1...600, step: 1)
                } label: {
                    RowLabel("Image duration", "How long each image shows when a playlist plays")
                }
                Picker("Audio output", selection: $show.settings.extrasAudioDevice) {
                    Text("System Output").tag(String?.none)
                    ForEach(audioOutputs, id: \.uid) { Text($0.name).tag(Optional($0.uid)) }
                }
                LabeledContent("Volume") {
                    Slider(value: $show.settings.extrasVolume, in: 0...1)
                        .frame(width: 160)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LogicSettings: View {
    @ObservedObject var show: Show

    var body: some View {
        Form {
            Section("Source") {
                Picker(selection: Binding(get: { show.settings.logicMac },
                                          set: { if let t = $0 { show.connectLogic(t) } else { show.disconnectLogic() } })) {
                    Text("None").tag(LinkTarget?.none)
                    ForEach(show.linkChoices, id: \.self) { Text($0.name).tag(Optional($0)) }
                } label: {
                    RowLabel("Source Mac", connectionText)
                }
                LabeledContent {
                    Text(show.hasMIDISession ? show.midiSessionName : "None")
                        .foregroundStyle(.secondary)
                } label: {
                    RowLabel("Network MIDI session", "On this Mac. Set up once in Audio MIDI Setup.")
                }
            }
            Section("Timecode") {
                LabeledContent {
                    Text(show.logic.fps ?? "—").foregroundStyle(.secondary)
                } label: {
                    RowLabel("Frame rate", "Taken from the source. Use 24 or 25 (in Logic: Project Settings → Synchronization).")
                }
                Toggle(isOn: $show.settings.acceptOnlyLogic) {
                    RowLabel("Accept MIDI only from Source Mac", "Ignore USB and other MIDI devices on this Mac")
                }
                .toggleStyle(.switch)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var connectionText: String {
        switch show.logic.state {
        case .connected: return "Connected · reconnects by itself"
        case .waiting: return show.settings.logicMac == nil ? "Choose the Mac that sends timecode (Logic, Ableton …)" : "Connecting…"
        case .lost: return "Connection lost · reconnecting…"
        case .noSession: return "No network MIDI session on this Mac"
        }
    }
}

private struct OutputSettings: View {
    @ObservedObject var show: Show
    @State private var modes: [DisplayModeRef] = []
    @State private var pending: Pending?

    /// Пробный режим, ждущий Keep / Revert
    struct Pending {
        let wanted: DisplayModeRef?
        let previous: DisplayModeRef?
        let screen: NSScreen
        var secondsLeft: Int
    }

    var body: some View {
        Form {
            Section("Stage Display") {
                Picker(selection: $show.settings.display) {
                    Text("First external display").tag(DisplayChoice.firstExternal)
                    ForEach(displayRefs, id: \.self) { ref in
                        Text(ref.name + (connected(ref) ? "" : " (not connected)")).tag(DisplayChoice.specific(ref))
                    }
                    Divider()
                    Text("Window (test)").tag(DisplayChoice.window)
                } label: {
                    RowLabel("Display", "Found again by itself when plugged back in")
                }
                Picker(selection: resolutionBinding) {
                    Text("Default").tag(DisplayModeRef?.none)
                    ForEach(modes, id: \.self) { Text($0.title).tag(Optional($0)) }
                } label: {
                    RowLabel("Resolution", show.stageScreen == nil ? "The stage display is not connected"
                                                                   : "Modes the display reports, including hidden ones")
                }
                .disabled(show.stageScreen == nil)
                Picker("Scale", selection: Binding(get: { show.settings.scale }, set: { show.setScale($0) })) {
                    ForEach(ScaleMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle(isOn: $show.settings.hideDock) {
                    RowLabel("Hide Dock on stage display", "The Dock never slides up over the video")
                }
                .toggleStyle(.switch)
                Toggle("Hide pointer", isOn: $show.settings.hidePointer)
                    .toggleStyle(.switch)
            }
            Section("Logo") {
                LabeledContent {
                    Button("Choose…", action: show.chooseLogo)
                } label: {
                    RowLabel(show.settings.logoPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No logo",
                             "Loops between songs and after Stop on the source")
                }
            }
            Section("While the Player Restarts") {
                Picker(selection: $show.settings.restartScreen) {
                    Text("Image").tag(RestartScreen.image)
                    Text("Black").tag(RestartScreen.black)
                } label: {
                    RowLabel("Stage screen shows", "About 1 s after a crash, until the show is back")
                }
                if show.settings.restartScreen == .image {
                    LabeledContent {
                        Button("Choose…", action: show.chooseRestartImage)
                    } label: {
                        RowLabel("Image", show.settings.restartImagePath.map { URL(fileURLWithPath: $0).lastPathComponent }
                                 ?? "None — black until you choose one")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: loadModes)
        .onChange(of: show.settings.display) { _, _ in loadModes() }
    }

    private func loadModes() {
        guard let screen = show.stageScreen else {
            modes = []
            return
        }
        modes = DisplayModes.all(OutputController.displayID(screen)).map(\.ref)
    }

    private var resolutionBinding: Binding<DisplayModeRef?> {
        Binding(get: {
            guard let screen = show.stageScreen else { return nil }
            return show.settings.resolutions[show.stageKey(screen)]
        }, set: { wanted in
            guard let screen = show.stageScreen else { return }
            let previous = show.tryResolution(wanted, on: screen)
            askToKeep(Pending(wanted: wanted, previous: previous, screen: screen, secondsLeft: 15))
        })
    }

    /// «Keep this resolution?» — без ответа через 15 с режим возвращается сам
    private func askToKeep(_ p: Pending) {
        let alert = NSAlert()
        alert.messageText = "Keep this resolution?"
        let name = p.screen.localizedName
        let title = p.wanted?.title ?? "the default resolution"
        func text(_ left: Int) -> String {
            "\(name) is now \(title). The previous resolution comes back in \(left) seconds."
        }
        alert.informativeText = text(p.secondsLeft)
        alert.addButton(withTitle: "Keep")
        alert.addButton(withTitle: "Revert")
        var left = p.secondsLeft
        let timer = Timer(timeInterval: 1, repeats: true) { t in
            left -= 1
            alert.informativeText = text(left)
            if left <= 0 {
                t.invalidate()
                NSApp.abortModal()
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let response = alert.runModal()
        timer.invalidate()
        if response == .alertFirstButtonReturn {
            show.keepResolution(p.wanted, on: p.screen)
        } else {
            show.revertResolution(to: p.previous, on: p.screen)
        }
        loadModes()
    }

    private var displayRefs: [DisplayRef] {
        var refs = NSScreen.screens.map(OutputController.ref(for:))
        if case .specific(let saved) = show.settings.display, !refs.contains(saved) { refs.append(saved) }
        return refs
    }

    private func connected(_ ref: DisplayRef) -> Bool {
        NSScreen.screens.contains { OutputController.ref(for: $0) == ref }
    }
}

private struct HelpSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Open Help") { HelpWindow.show() }
                } label: {
                    RowLabel("Setup and troubleshooting", "The source Mac, network MIDI, the stage display, the checklist before a show")
                }
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Log.url]) }
                } label: {
                    RowLabel("Log", "What happened during the show, second by second")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
