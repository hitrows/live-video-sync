import AppKit

/// Extras: плейлисты и их запуск
extension Show {
    // MARK: - Extras


    /// ▶ Play в шапке плейлиста — по порядку, с повтором плейлиста
    func playPlaylist(_ id: UUID, from itemID: UUID? = nil) {
        guard let playlist = playlist(id) else { return }
        let items = playlist.items.filter { media[$0.path]?.playable ?? false }
        guard !items.isEmpty else { return }
        let start = itemID.flatMap { i in items.firstIndex { $0.id == i } } ?? 0
        startExtras(items, playlist: id, from: start, mode: .playlist(playlist.repeatMode))
        Log.info("Extras: плейлист «\(playlist.name)» с \(start + 1)-го, повтор \(playlist.repeatMode.title)")
    }

    /// ▶ у строки — один файл: видео до конца, потом логотип; картинка — бесконечно
    func playExtra(_ item: PlaylistItem, in playlistID: UUID) {
        guard media[item.path]?.playable ?? false else { return }
        startExtras([item], playlist: playlistID, from: 0, mode: .single)
    }

    func startExtras(_ items: [PlaylistItem], playlist: UUID, from index: Int, mode: ExtrasPlayer.Mode) {
        let entries = items.map { ExtrasPlayer.Entry(url: $0.url, isImage: media[$0.path]?.isImage ?? false) }
        extrasItems = items
        extrasPlaylist = playlist
        let now = HostTime.now
        engine.extras.play(entries, from: index, mode: mode, now: now)
        director.startExtras(at: now)
        syncManualState()
    }

    func playlist(_ id: UUID?) -> Playlist? {
        settings.playlists.first { $0.id == id }
    }

    func editPlaylist(_ id: UUID, _ body: (inout Playlist) -> Void) {
        guard let i = settings.playlists.firstIndex(where: { $0.id == id }) else { return }
        body(&settings.playlists[i])
    }

    @discardableResult
    func newPlaylist() -> UUID {
        var title = "Untitled Playlist"
        var n = 2
        while settings.playlists.contains(where: { $0.name == title }) {
            title = "Untitled Playlist \(n)"
            n += 1
        }
        let playlist = Playlist(name: title)
        settings.playlists.append(playlist)
        Log.info("Новый плейлист Extras: \(title)")
        return playlist.id
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        editPlaylist(id) { $0.name = trimmed }
    }

    func deletePlaylist(_ id: UUID) {
        if extrasPlaylist == id { director.stopManual(); engine.extras.stop() }
        settings.playlists.removeAll { $0.id == id }
    }

    func setRepeat(_ mode: RepeatMode, for id: UUID) {
        editPlaylist(id) { $0.repeatMode = mode }
        if extrasPlaylist == id { engine.extras.setRepeat(mode) }
    }

    func addFiles(_ urls: [URL], toPlaylist id: UUID, at index: Int? = nil) {
        let files = urls.flatMap(expandFolder).filter(Library.isMedia)
        guard !files.isEmpty else { return }
        editPlaylist(id) { p in
            let at = min(max(0, index ?? p.items.count), p.items.count)
            p.items.insert(contentsOf: files.map { PlaylistItem(path: $0.path) }, at: at)
        }
        inspectMedia()
    }

    func removePlaylistItems(_ ids: Set<UUID>, from id: UUID) {
        editPlaylist(id) { $0.items.removeAll { ids.contains($0.id) } }
    }

    func movePlaylistItems(in id: UUID, from offsets: IndexSet, to destination: Int) {
        editPlaylist(id) { $0.items.move(fromOffsets: offsets, toOffset: destination) }
    }

    func renamePlaylistItem(_ itemID: UUID, in id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        editPlaylist(id) { p in
            guard let i = p.items.firstIndex(where: { $0.id == itemID }) else { return }
            p.items[i].title = trimmed.isEmpty ? nil : trimmed
        }
    }

    func replacePlaylistFile(_ itemID: UUID, in id: UUID) {
        guard let item = playlist(id)?.items.first(where: { $0.id == itemID }) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image]
        panel.prompt = "Choose"
        panel.directoryURL = item.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editPlaylist(id) { p in
            guard let i = p.items.firstIndex(where: { $0.id == itemID }) else { return }
            p.items[i].path = url.path
        }
        inspectMedia()
    }
}
