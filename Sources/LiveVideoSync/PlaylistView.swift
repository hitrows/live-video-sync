import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Открытый плейлист Extras: превью и Now Playing сверху, файлы снизу
struct PlaylistDetail: View {
    @ObservedObject var show: Show
    let playlistID: UUID
    let search: String

    var body: some View {
        if let playlist = show.playlist(playlistID) {
            VStack(alignment: .leading, spacing: 0) {
                Banners(show: show)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                HStack(alignment: .top, spacing: 24) {
                    PreviewPanel(show: show)
                        .frame(maxWidth: 620)
                    NowPlayingPanel(show: show)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                PlaylistHeader(show: show, playlist: playlist)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                PlaylistItems(show: show, playlist: playlist, search: search)
                    .frame(minHeight: 120, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct PlaylistHeader: View {
    @ObservedObject var show: Show
    let playlist: Playlist

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.title.weight(.bold))
                    .lineLimit(1)
                Text("\(playlist.items.count) \(playlist.items.count == 1 ? "item" : "items") · playlist · shared by all setlists")
                    .foregroundStyle(.secondary)
            }
            Button { show.playPlaylist(playlist.id) } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(playlist.items.isEmpty)
            .help("Play the playlist from the first item")
            HStack(spacing: 6) {
                Text("Repeat").foregroundStyle(.secondary)
                Picker("Repeat", selection: Binding(get: { playlist.repeatMode }, set: { show.setRepeat($0, for: playlist.id) })) {
                    ForEach(RepeatMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Text("Images: \(Int(show.settings.extrasImageDuration)) s each · change in Settings")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
    }
}

private struct PlaylistItems: View {
    @ObservedObject var show: Show
    let playlist: Playlist
    let search: String
    @State private var selection = Set<UUID>()
    @State private var renaming: UUID?

    private var filtered: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    private var rows: [(number: Int, item: PlaylistItem)] {
        let all = playlist.items.enumerated().map { ($0.offset + 1, $0.element) }
        guard filtered else { return all }
        return all.filter { $0.1.displayName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        if playlist.items.isEmpty {
            // Зона «перетащи файлы» — только в пустом плейлисте
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Drag videos and images here")
                    .font(.title3.weight(.semibold))
                Text("Band logos, ads, intros. Videos play with sound.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(.tertiary))
            .padding(24)
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                show.addFiles(urls, toPlaylist: playlist.id)
                return true
            }
        } else {
            List(selection: $selection) {
                ForEach(rows, id: \.item.id) { row in
                    PlaylistRow(show: show, playlist: playlist, item: row.item, number: row.number, renaming: $renaming)
                        .tag(row.item.id)
                }
                .onMove(perform: filtered ? nil : { show.movePlaylistItems(in: playlist.id, from: $0, to: $1) })
                .onInsert(of: [.fileURL]) { index, providers in
                    Task { @MainActor in
                        var urls: [URL] = []
                        for p in providers {
                            if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                               let u = URL(dataRepresentation: data, relativeTo: nil) { urls.append(u) }
                        }
                        show.addFiles(urls, toPlaylist: playlist.id, at: index)
                    }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: UUID.self) { ids in
                if ids.count == 1, let item = playlist.items.first(where: { $0.id == ids.first }) {
                    PlaylistItemMenu(show: show, playlist: playlist, item: item, renaming: $renaming)
                } else if !ids.isEmpty {
                    Button("Remove from Playlist", role: .destructive) { show.removePlaylistItems(ids, from: playlist.id) }
                }
            } primaryAction: { ids in
                // Двойной щелчок — этот файл один раз
                guard ids.count == 1, let item = playlist.items.first(where: { $0.id == ids.first }) else { return }
                show.playExtra(item, in: playlist.id)
            }
            .onKeyPress(.return) {
                guard renaming == nil, selection.count == 1 else { return .ignored }
                renaming = selection.first
                return .handled
            }
            .onDeleteCommand {
                show.removePlaylistItems(selection, from: playlist.id)
                selection = []
            }
        }
    }
}

private struct PlaylistItemMenu: View {
    @ObservedObject var show: Show
    let playlist: Playlist
    let item: PlaylistItem
    @Binding var renaming: UUID?

    var body: some View {
        Button("Play") { show.playExtra(item, in: playlist.id) }
        Button("Play from Here") { show.playPlaylist(playlist.id, from: item.id) }
        Divider()
        if show.settings.logoPath == item.path {
            Button { } label: { Label("Set as Logo", systemImage: "checkmark") }
        } else {
            Button("Set as Logo") { show.setLogo(item.path) }
                .disabled(show.media[item.path]?.playable != true)
        }
        Divider()
        Button("Rename") { renaming = item.id }
        Button("Replace File…") { show.replacePlaylistFile(item.id, in: playlist.id) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            .disabled(show.media[item.path]?.missing == true)
        Divider()
        Button("Remove from Playlist", role: .destructive) { show.removePlaylistItems([item.id], from: playlist.id) }
    }
}

private struct PlaylistRow: View {
    @ObservedObject var show: Show
    let playlist: Playlist
    let item: PlaylistItem
    let number: Int
    @Binding var renaming: UUID?
    @State private var hovering = false
    @State private var draft = ""
    /// Окно стало неактивным — onHover «выход» может не прийти, и «•••» залипает на строке
    @Environment(\.controlActiveState) private var activeState
    @FocusState private var editing: Bool

    private var info: MediaInfo? { show.media[item.path] }
    private var isPlaying: Bool { show.extrasNow?.playlist == playlist.id && show.extrasNow?.item == item.id }
    private var onAir: Bool { isPlaying && show.settings.live }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let info, let problem = info.problem, !info.playable || !info.warnings.isEmpty {
                    Image(systemName: "exclamationmark.triangle")
                        .fontWeight(.light)
                        .foregroundStyle(.secondary)
                        .help(problem)
                }
            }
            .frame(width: 18)
            leading
                .frame(width: 28, alignment: .trailing)
            title
            if info?.hasAudio == true {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(.secondary)
                    .help("Plays with sound")
            }
            Spacer(minLength: 12)
            // Этот файл — логотип: тот же значок, что у кнопки Logo; своя колонка перед типом, как ножницы в сет-листе
            Group {
                if show.settings.logoPath == item.path {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("This file is the logo")
                }
            }
            .frame(width: 18)
            Text(info?.isImage == true ? "IMAGE" : "VIDEO")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(.quaternary))
                .frame(width: 52, alignment: .leading)
            Text(durationText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Menu {
                PlaylistItemMenu(show: show, playlist: playlist, item: item, renaming: $renaming)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .opacity(hovering ? 1 : 0)
            .frame(width: 24)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onChange(of: activeState) { _, state in if state != .key { hovering = false } }
    }

    private var durationText: String {
        guard let info, info.playable else { return "—" }
        // Один вид для картинок и видео: 0:10
        return Show.minutes(info.isImage ? show.settings.extrasImageDuration : info.duration)
    }

    @ViewBuilder
    private var leading: some View {
        if isPlaying {
            Image(systemName: "play.tv")
                .foregroundStyle(onAir ? .red : .secondary)
        } else if hovering, info?.playable == true {
            Button { show.playExtra(item, in: playlist.id) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.plain)
                .help(info?.isImage == true ? "Show this image until something else plays"
                                             : "Play this video once, then the logo")
        } else {
            Text("\(number)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var title: some View {
        if renaming == item.id {
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($editing)
                .frame(maxWidth: 360)
                .onAppear {
                    draft = item.displayName
                    editing = true
                }
                .onSubmit { commit() }
                .onExitCommand { renaming = nil }
                .onChange(of: editing) { _, focused in if !focused { commit() } }
        } else {
            Text(item.displayName)
                .lineLimit(1)
                .foregroundStyle(onAir ? .red : info?.missing == true ? .secondary : .primary)
        }
    }

    private func commit() {
        guard renaming == item.id else { return }
        show.renamePlaylistItem(item.id, in: playlist.id, to: draft)
        renaming = nil
    }
}
