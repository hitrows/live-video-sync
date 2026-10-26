import AppKit

/// Экран сцены: тестовое окно, разрешение, обои на время перезапуска, курсор, Screen Fit
extension Show {
    // MARK: - Экран сцены: разрешение и обои на время перезапуска

    /// Экран сцены, если подключён (для Settings → Output)
    var stageScreen: NSScreen? {
        settings.testWindow ? nil : OutputController.targetScreen(for: settings.display)
    }

    /// Куда вывод: экран сцены или тестовое окно
    var outputChoice: DisplayChoice { settings.testWindow ? .window : settings.display }

    /// «A200 HDMI · 1280 × 800 px» — экран и размер вывода в пикселях
    var testPatternTitle: String {
        let size = engine.rootLayer.bounds.size
        let scale = settings.testWindow ? (NSScreen.main?.backingScaleFactor ?? 1) : (stageScreen?.backingScaleFactor ?? 1)
        let name: String
        switch outputState {
        case .live(let display): name = settings.testWindow ? "Test window" : display
        default: name = settings.testWindow ? "Test window" : expectedDisplayName
        }
        engine.pixelScale = scale
        return "\(name) · \(Int(size.width * scale)) × \(Int(size.height * scale)) px"
    }

    func toggleTestWindow() {
        settings.testWindow.toggle()
        Log.info(settings.testWindow ? "Вывод в тестовое окно" : "Вывод на экран сцены")
    }

    func stageKey(_ screen: NSScreen) -> String {
        DisplayModes.displayKey(OutputController.ref(for: screen))
    }


    func stageScreenFound(_ screen: NSScreen) {
        let key = stageKey(screen)
        let id = OutputController.displayID(screen)
        if let wanted = settings.resolutions[key], resolutionTrialKey != key, modeAttempts[key] != wanted {
            modeAttempts[key] = wanted
            if stage.originalModes[key] == nil, let current = DisplayModes.current(id), current != wanted {
                stage.originalModes[key] = current
            }
            DisplayModes.set(wanted, on: id)
        }
        if settings.live { setRestartWallpaper(on: screen) }
    }

    /// Пробный режим из Settings: ставится сразу, сохраняется только после Keep
    func tryResolution(_ wanted: DisplayModeRef?, on screen: NSScreen) -> DisplayModeRef? {
        let key = stageKey(screen)
        let id = OutputController.displayID(screen)
        let before = DisplayModes.current(id)
        resolutionTrialKey = key
        if let wanted {
            if stage.originalModes[key] == nil, let before { stage.originalModes[key] = before }
            DisplayModes.set(wanted, on: id)
        } else if let original = stage.originalModes[key] {
            DisplayModes.set(original, on: id)
        }
        return before
    }

    func keepResolution(_ wanted: DisplayModeRef?, on screen: NSScreen) {
        let key = stageKey(screen)
        resolutionTrialKey = nil
        modeAttempts[key] = wanted
        settings.resolutions[key] = wanted
        if wanted == nil { stage.originalModes[key] = nil }
        Log.info("Разрешение экрана сцены: \(wanted?.title ?? "Default") — сохранено")
    }

    func revertResolution(to mode: DisplayModeRef?, on screen: NSScreen) {
        resolutionTrialKey = nil
        modeAttempts[stageKey(screen)] = nil
        guard let mode else { return }
        DisplayModes.set(mode, on: OutputController.displayID(screen))
        Log.info("Разрешение экрана сцены возвращено: \(mode.title)")
    }

    /// Картинка (или чёрное) обоями экрана сцены: если программа упадёт, пока она перезапускается — видно это, а не рабочий стол
    func setRestartWallpaper(on screen: NSScreen) {
        guard let url = restartImageURL else { return }
        let key = stageKey(screen)
        let current = NSWorkspace.shared.desktopImageURL(for: screen)
        guard current?.standardizedFileURL != url.standardizedFileURL else { return }
        if stage.previousWallpapers[key] == nil, let current { stage.previousWallpapers[key] = current.path }
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true,
                .fillColor: NSColor.black,
            ])
            Log.info("Обои экрана сцены: \(url.lastPathComponent)")
        } catch {
            Log.info("Не удалось поставить обои экрана сцены: \(error.localizedDescription)")
        }
    }

    var restartImageURL: URL? {
        if settings.restartScreen == .image, let path = settings.restartImagePath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return Store.blackImageURL
    }

    func chooseRestartImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use Image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.restartImagePath = url.path
        settings.restartScreen = .image
        if let screen = stageScreen, settings.live { setRestartWallpaper(on: screen) }
    }

    /// Штатный выход: вернуть экран сцены и сразу записать настройки
    func prepareToQuit() {
        restoreStageScreen()
        Store.flush(settings)
    }

    /// Штатный выход: вернуть прежние разрешение и обои экрана сцены
    func restoreStageScreen() {
        for screen in NSScreen.screens {
            let key = stageKey(screen)
            if let original = stage.originalModes[key] {
                DisplayModes.set(original, on: OutputController.displayID(screen))
                stage.originalModes[key] = nil
            }
            if let path = stage.previousWallpapers[key] {
                try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])
                stage.previousWallpapers[key] = nil
                Log.info("Обои экрана «\(screen.localizedName)» возвращены")
            }
        }
    }

    /// Dock переезжает на экран, где курсор упёрся в нижний край. Спрятать Dock только на одном экране macOS не даёт,
    /// поэтому во время вывода курсор на экран сцены не пускаем — и Dock туда не попадёт. Основной экран не трогаем.
    func keepPointerOffStage() {
        guard settings.live, !settings.testWindow, let stage = output.currentScreen else { return }
        let mouse = NSEvent.mouseLocation
        guard stage.frame.contains(mouse),
              let other = NSScreen.screens.filter({ $0 != stage }).min(by: { distance($0.frame, mouse) < distance($1.frame, mouse) }),
              let primary = NSScreen.screens.first else { return }
        // Ближайшая точка соседнего экрана, на 2 pt внутрь
        let f = other.frame.insetBy(dx: 2, dy: 2)
        let p = CGPoint(x: min(max(mouse.x, f.minX), f.maxX), y: min(max(mouse.y, f.minY), f.maxY))
        CGWarpMouseCursorPosition(CGPoint(x: p.x, y: primary.frame.height - p.y))
    }

    func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    // MARK: - Screen Fit

    var venuePresetName: String? {
        settings.venuePresets.first { $0.id == settings.venuePreset }?.name
    }

    func choosePreset(_ id: UUID) {
        guard let preset = settings.venuePresets.first(where: { $0.id == id }) else { return }
        settings.venuePreset = id
        settings.screenFit = preset.fit
        Log.info("Screen Fit: пресет «\(preset.name)»")
    }

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let preset = VenuePreset(name: trimmed, fit: settings.screenFit)
        settings.venuePresets.append(preset)
        settings.venuePreset = preset.id
        Log.info("Screen Fit: сохранён пресет «\(trimmed)»")
    }

    func renamePreset(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = settings.venuePresets.firstIndex(where: { $0.id == id }) else { return }
        settings.venuePresets[i].name = trimmed
    }

    func deletePreset(_ id: UUID) {
        settings.venuePresets.removeAll { $0.id == id }
        if settings.venuePreset == id { settings.venuePreset = nil }
    }
}
