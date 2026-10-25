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
                .tabItem { Label("Logic", systemImage: "pianokeys") }
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
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LogicSettings: View {
    @ObservedObject var show: Show

    var body: some View {
        Form {
            Section("Logic Mac") {
                Picker(selection: Binding(get: { show.settings.logicMac },
                                          set: { if let t = $0 { show.connectLogic(t) } else { show.disconnectLogic() } })) {
                    Text("None").tag(LinkTarget?.none)
                    ForEach(show.linkChoices, id: \.self) { Text($0.name).tag(Optional($0)) }
                } label: {
                    RowLabel("Mac with Logic", connectionText)
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
                    RowLabel("Frame rate", "Taken from Logic. Use 24 or 25 in Project Settings → Synchronization.")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var connectionText: String {
        switch show.logic.state {
        case .connected: return "Connected · reconnects by itself"
        case .waiting: return show.settings.logicMac == nil ? "Choose the Mac that runs Logic" : "Connecting…"
        case .lost: return "Connection lost · reconnecting…"
        case .noSession: return "No network MIDI session on this Mac"
        }
    }
}

private struct OutputSettings: View {
    @ObservedObject var show: Show

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
                Picker("Scale", selection: Binding(get: { show.settings.scale }, set: { show.setScale($0) })) {
                    ForEach(ScaleMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section("Logo") {
                LabeledContent {
                    Button("Choose…", action: show.chooseLogo)
                } label: {
                    RowLabel(show.settings.logoPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No logo",
                             "Loops between songs and after Stop in Logic")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
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
                    RowLabel("Setup and troubleshooting", "Logic, network MIDI, the stage display, the checklist before a show")
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
