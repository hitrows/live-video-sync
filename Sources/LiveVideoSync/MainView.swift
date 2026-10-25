import AppKit
import SwiftUI

/// Главное окно: библиотека слева, справа — Show (превью, Now Playing, сет-лист) или Screen Fit
struct MainView: View {
    @ObservedObject var show: Show
    @ObservedObject var ui: UIState
    private let search = ""

    var body: some View {
        NavigationSplitView {
            Sidebar(show: show, ui: ui)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            detail
        }
        .navigationTitle("Live Video Sync")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $ui.mode) {
                    Text("Show").tag(UIState.Mode.show)
                    Text("Screen Fit").tag(UIState.Mode.screenFit)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }
            ToolbarItem(placement: .primaryAction) {
                liveButton
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if ui.mode == .screenFit {
            ScreenFitView(show: show)
        } else if show.settings.setlists.isEmpty {
            FirstLaunchView(show: show, ui: ui)
        } else if let id = ui.selectedSetlist, show.setlist(id) != nil {
            SetlistDetail(show: show, ui: ui, setlistID: id, search: search)
        } else if let id = ui.selectedPlaylist, show.playlist(id) != nil {
            PlaylistDetail(show: show, playlistID: id, search: search)
        } else {
            ContentUnavailableView("No Setlist Selected", systemImage: "music.note.list",
                                   description: Text("Choose a setlist in the sidebar."))
        }
    }

    private var liveButton: some View {
        Group {
            if show.settings.live {
                Button("Stop Output") { ui.toggleLive(show) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            } else {
                Button("Go Live") { ui.toggleLive(show) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .help(show.settings.live ? "Stop the output to the stage screen (⌘L)" : "Start the output to the stage screen (⌘L)")
    }

    /// «LIVE · A200 HDMI» — плюс то, что сейчас не так
    private var subtitle: String {
        var parts: [String]
        switch show.outputState {
        case .off: parts = ["Output off"]
        case .live(let display): parts = ["LIVE", display]
        case .waitingForDisplay: parts = ["LIVE", "Waiting for display…"]
        }
        if let preset = show.venuePresetName { parts.append("preset «\(preset)»") }
        switch show.logic.state {
        case .lost: parts.append("Logic not connected")
        case .noSession: parts.append("No network MIDI session")
        default: break
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Боковая панель

private struct Sidebar: View {
    @ObservedObject var show: Show
    @ObservedObject var ui: UIState
    @State private var renaming: Setlist?
    @State private var renamingPlaylist: Playlist?
    @State private var newName = ""
    @State private var deleting: Setlist?
    @State private var deletingPlaylist: Playlist?

    var body: some View {
        List(selection: $ui.selection) {
            Section("Setlists") {
                ForEach(show.settings.setlists) { setlist in
                    HStack {
                        Text(setlist.name).lineLimit(1)
                        Spacer()
                        if setlist.id == show.settings.activeSetlist {
                            // Красный — только у того, что сейчас на экране сцены
                            let onAir = show.settings.live && show.extrasNow == nil
                            Image(systemName: "play.rectangle")
                                .foregroundStyle(onAir ? .red : .secondary)
                                .help(onAir ? "Active setlist — on air" : "Active setlist")
                        }
                    }
                    .tag(UIState.SidebarItem.setlist(setlist.id))
                    .contextMenu {
                        Button("Make Active") { show.makeActive(setlist.id) }
                            .disabled(setlist.id == show.settings.activeSetlist)
                        Button("Rename…") {
                            newName = setlist.name
                            renaming = setlist
                        }
                        Divider()
                        Button("Delete Setlist…") { deleting = setlist }
                    }
                }
            }
            Section("Extras") {
                ForEach(show.settings.playlists) { playlist in
                    HStack {
                        Text(playlist.name).lineLimit(1)
                        Spacer()
                        if show.extrasNow?.playlist == playlist.id {
                            Image(systemName: "speaker.wave.2")
                                .foregroundStyle(show.settings.live ? .red : .secondary)
                                .help("Playing now, instead of the setlist")
                        }
                    }
                    .tag(UIState.SidebarItem.playlist(playlist.id))
                    .contextMenu {
                        Button("Play") { show.playPlaylist(playlist.id) }
                            .disabled(playlist.items.isEmpty)
                        Button("Rename…") {
                            newName = playlist.name
                            renamingPlaylist = playlist
                        }
                        Divider()
                        Button("Delete Playlist…") { deletingPlaylist = playlist }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("New Setlist") { ui.newSetlist(show) }
                    Button("New Playlist") { ui.newPlaylist(show) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New setlist or Extras playlist")
                Spacer()
            }
            .padding(10)
        }
        .alert("Rename Setlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let s = renaming { show.renameSetlist(s.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Playlist", isPresented: Binding(get: { renamingPlaylist != nil }, set: { if !$0 { renamingPlaylist = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let p = renamingPlaylist { show.renamePlaylist(p.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete “\(deletingPlaylist?.name ?? "")”?", isPresented: Binding(get: { deletingPlaylist != nil }, set: { if !$0 { deletingPlaylist = nil } })) {
            Button("Delete", role: .destructive) {
                if let p = deletingPlaylist {
                    show.deletePlaylist(p.id)
                    if ui.selectedPlaylist == p.id { ui.selection = show.settings.setlists.first.map { .setlist($0.id) } }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files stay on the disk.")
        }
        .alert("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let s = deleting {
                    show.deleteSetlist(s.id)
                    if ui.selectedSetlist == s.id { ui.selection = show.settings.setlists.first.map { .setlist($0.id) } }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The video files stay on the disk. Learned markers of this setlist are lost.")
        }
    }
}

// MARK: - Первый запуск

private struct FirstLaunchView: View {
    @ObservedObject var show: Show
    @ObservedObject var ui: UIState

    var body: some View {
        ContentUnavailableView {
            Label("No Setlists Yet", systemImage: "music.note.list")
        } description: {
            Text("Create a setlist and drag your song videos into it.\nEach song gets a marker note: song 1 = C1, song 2 = C#1 …")
        } actions: {
            Button("New Setlist") { ui.newSetlist(show) }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Баннеры

/// Баннер под панелью инструментов: что не так и что сделать
struct Banner: View {
    let symbol: String
    let text: String
    var button: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
            Text(text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let button {
                Button(button, action: action)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.25)))
    }
}

struct Banners: View {
    @ObservedObject var show: Show

    var body: some View {
        VStack(spacing: 8) {
            if case .waitingForDisplay(let name) = show.outputState {
                Banner(symbol: "display.trianglebadge.exclamationmark",
                       text: "Stage display not found. Connect \(name) — the show comes back on it by itself.",
                       button: "Display Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
                }
            }
            if show.logic.state == .noSession {
                Banner(symbol: "pianokeys",
                       text: "This Mac has no network MIDI session, so Logic can’t reach it. In Audio MIDI Setup → Network, press + under My Sessions and tick it — once.",
                       button: "Open Audio MIDI Setup") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
                }
            } else if show.logic.state == .lost {
                Banner(symbol: "wifi.exclamationmark",
                       text: "No signal from Logic. The current video keeps playing to the end, then the logo. Reconnecting automatically…",
                       button: show.settings.logicMac == nil ? nil : "Reconnect Now") {
                    if let mac = show.settings.logicMac { show.connectLogic(mac) }
                }
            }
        }
    }
}
