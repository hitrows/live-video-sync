import AppKit

/// Сеты: песни, ноты-метки, файлы, обрезка, логотип
extension Show {
    // MARK: - Ноты-метки

    /// Нота-метка песни
    func note(_ item: SetlistItem, in setlist: Setlist? = nil) -> Int {
        if let n = item.note { return n }
        let list = setlist ?? settings.setlists.first { $0.items.contains { $0.id == item.id } }
        let index = list?.items.firstIndex { $0.id == item.id } ?? 0
        return settings.markerBaseNote + index
    }

    /// Следующая свободная нота в сете (после самой высокой)
    func nextFreeNote(in setlist: Setlist) -> Int {
        let used = setlist.items.compactMap(\.note)
        return min(127, (used.max().map { $0 + 1 }) ?? settings.markerBaseNote)
    }

    /// Песням без ноты — ноты по порядку (старые настройки: нота = место в списке)
    func assignMissingNotes() {
        for s in settings.setlists.indices where settings.setlists[s].items.contains(where: { $0.note == nil }) {
            for i in settings.setlists[s].items.indices where settings.setlists[s].items[i].note == nil {
                settings.setlists[s].items[i].note = settings.markerBaseNote + i
            }
        }
    }

    /// Сменить ноту песни; если она занята другой песней сета — поменяться с ней
    func setNote(_ note: Int, for itemID: UUID, in setlistID: UUID) {
        edit(setlistID) { s in
            guard let i = s.items.firstIndex(where: { $0.id == itemID }) else { return }
            let old = s.items[i].note
            if let j = s.items.firstIndex(where: { $0.note == note && $0.id != itemID }) { s.items[j].note = old }
            s.items[i].note = note
        }
        Log.info("Нота-метка: \(Self.noteName(note))")
    }

    // MARK: - Сеты

    func setlist(_ id: UUID?) -> Setlist? {
        settings.setlists.first { $0.id == id }
    }

    /// Песня активного сета по номеру (1…)
    func activeItem(_ number: Int) -> SetlistItem? {
        guard let items = settings.active?.items, number >= 1, number <= items.count else { return nil }
        return items[number - 1]
    }

    func edit(_ id: UUID, _ body: (inout Setlist) -> Void) {
        guard let i = settings.setlists.firstIndex(where: { $0.id == id }) else { return }
        body(&settings.setlists[i])
    }

    @discardableResult
    func newSetlist(name: String? = nil) -> UUID {
        let base = name ?? "Untitled Setlist"
        var title = base
        var n = 2
        while settings.setlists.contains(where: { $0.name == title }) {
            title = "\(base) \(n)"
            n += 1
        }
        let setlist = Setlist(name: title)
        settings.setlists.append(setlist)
        // Первый сет сразу активный — играть больше нечему
        if settings.activeSetlist == nil { settings.activeSetlist = setlist.id }
        Log.info("Новый сет: \(title)")
        return setlist.id
    }

    func renameSetlist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        edit(id) { $0.name = trimmed }
    }

    func deleteSetlist(_ id: UUID) {
        guard let s = setlist(id) else { return }
        settings.setlists.removeAll { $0.id == id }
        if settings.activeSetlist == id { settings.activeSetlist = nil }
        Log.info("Сет удалён: \(s.name)")
    }

    func makeActive(_ id: UUID) {
        guard let s = setlist(id) else { return }
        settings.activeSetlist = id
        Log.info("Активный сет: \(s.name)")
    }

    /// Добавить файлы в сет (перетаскивание или Add Files…); index — куда вставить
    func addFiles(_ urls: [URL], to id: UUID, at index: Int? = nil) {
        let files = urls.flatMap(expandFolder).filter(Library.isMedia)
        guard !files.isEmpty else { return }
        guard let current = setlist(id) else { return }
        var next = nextFreeNote(in: current)
        let items: [SetlistItem] = files.map { url in
            var item = SetlistItem(path: url.path)
            item.note = next
            next = min(127, next + 1)
            return item
        }
        edit(id) { s in
            let at = min(max(0, index ?? s.items.count), s.items.count)
            s.items.insert(contentsOf: items, at: at)
        }
        inspectMedia()
        Log.info("В сет добавлено файлов: \(files.count)")
    }

    /// Папку — её видео и картинки по имени
    func expandFolder(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [url] }
        return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func removeItems(_ ids: Set<UUID>, from setlistID: UUID) {
        edit(setlistID) { $0.items.removeAll { ids.contains($0.id) } }
    }

    func moveItems(in setlistID: UUID, from offsets: IndexSet, to destination: Int) {
        edit(setlistID) { $0.items.move(fromOffsets: offsets, toOffset: destination) }
    }

    /// Move to Position: песня встаёт на позицию (1…), остальные сдвигаются
    func moveItem(_ itemID: UUID, in setlistID: UUID, toPosition position: Int) {
        edit(setlistID) { s in
            guard let from = s.items.firstIndex(where: { $0.id == itemID }) else { return }
            let item = s.items.remove(at: from)
            s.items.insert(item, at: min(max(0, position - 1), s.items.count))
        }
    }

    func renameItem(_ itemID: UUID, in setlistID: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        edit(setlistID) { s in
            guard let i = s.items.firstIndex(where: { $0.id == itemID }) else { return }
            s.items[i].title = trimmed.isEmpty ? nil : trimmed
        }
    }

    func setTrim(_ itemID: UUID, in setlistID: UUID, start: Double, end: Double?) {
        edit(setlistID) { s in
            guard let i = s.items.firstIndex(where: { $0.id == itemID }) else { return }
            s.items[i].trimStart = max(0, start)
            s.items[i].trimEnd = end
        }
    }

    func resetMarker(_ itemID: UUID, in setlistID: UUID) {
        edit(setlistID) { s in
            guard let i = s.items.firstIndex(where: { $0.id == itemID }) else { return }
            s.items[i].marker = nil
        }
        Log.info("Метка сброшена")
    }

    func resetMarkers(in setlistID: UUID) {
        edit(setlistID) { s in
            for i in s.items.indices { s.items[i].marker = nil }
        }
        Log.info("Метки сета сброшены")
    }

    /// Replace File… и Locate… — выбрать другой файл для песни, метка и имя остаются
    func replaceFile(_ itemID: UUID, in setlistID: UUID) {
        guard let item = setlist(setlistID)?.items.first(where: { $0.id == itemID }) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image]
        panel.prompt = "Choose"
        panel.message = "Choose the file for “\(item.displayName)”"
        panel.directoryURL = item.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        edit(setlistID) { s in
            guard let i = s.items.firstIndex(where: { $0.id == itemID }) else { return }
            // Имя в списке сохраняем — его видит музыкант, а не имя файла
            if s.items[i].title == nil { s.items[i].title = item.displayName }
            s.items[i].path = url.path
            s.items[i].trimStart = 0
            s.items[i].trimEnd = nil
        }
        inspectMedia()
        Log.info("Файл песни заменён: \(url.lastPathComponent)")
    }

    func showInFinder(_ item: SetlistItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func info(_ item: SetlistItem) -> MediaInfo? { media[item.path] }

    /// Длительность песни с учётом обрезки
    func duration(_ item: SetlistItem) -> Double? {
        guard let info = media[item.path], info.playable, !info.isImage else { return nil }
        let end = min(item.trimEnd ?? info.duration, info.duration)
        return max(0.1, end - item.trimStart)
    }

    func totalDuration(_ setlist: Setlist) -> Double {
        setlist.items.compactMap(duration).reduce(0, +)
    }

    /// Set as Logo — из правого щелчка у файла Extras
    func setLogo(_ path: String) {
        settings.logoPath = path
        Log.info("Логотип: \(URL(fileURLWithPath: path).lastPathComponent)")
    }

    func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image]
        panel.prompt = "Use as Logo"
        if let path = settings.logoPath { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url { settings.logoPath = url.path }
    }
}
