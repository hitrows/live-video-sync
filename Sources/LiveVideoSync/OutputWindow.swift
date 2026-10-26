import AppKit
import IOKit.ps

/// Вид трансляции: держит слой видеодвижка, курсор над ним прозрачный
final class OutputView: NSView {
    let engine: VideoEngine
    private static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
    /// Settings → Output → Hide pointer
    static var hidePointer = true

    init(engine: VideoEngine) {
        self.engine = engine
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    required init?(coder: NSCoder) { fatalError() }

    func attach() {
        engine.rootLayer.removeFromSuperlayer()
        layer?.addSublayer(engine.rootLayer)
        engine.layout(bounds: bounds)
    }

    override func layout() {
        super.layout()
        engine.layout(bounds: bounds)
    }

    override func resetCursorRects() {
        guard Self.hidePointer else { return }
        addCursorRect(bounds, cursor: Self.blankCursor)
    }

    override var acceptsFirstResponder: Bool { false }
}

/// Окно без рамок поверх строки меню
private final class OutputWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Окно трансляции на выбранном экране. Экран пропал — окно прячется и ждёт; появился — возвращается само.
final class OutputController {
    let engine: VideoEngine
    var choice: DisplayChoice = .firstExternal { didSet { if choice != oldValue { apply() } } }
    var live = false { didSet { if live != oldValue { apply() } } }
    /// Экран сцены найден (подключили, сменился, пошёл эфир) — поставить разрешение и обои
    var onStageScreen: ((NSScreen) -> Void)?
    /// Где сейчас идёт трансляция (для монитора); nil — нигде
    private(set) var currentTarget: String?
    /// Экран сцены, на котором сейчас вывод (не тестовое окно)
    private(set) var currentScreen: NSScreen?

    private var window: NSWindow?
    private var windowIsTest = false
    private var applyScheduled = false
    private var lastScreenList = OutputController.screenList()

    init(engine: VideoEngine) {
        self.engine = engine
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            // macOS может слать это десятки раз в секунду (переходник, проектор ищет сигнал) — пишем только реальные изменения
            let list = Self.screenList()
            if list != self?.lastScreenList {
                Log.info("Экраны изменились: \(list)")
                self?.lastScreenList = list
            }
            self?.scheduleApply()
        }
        // После сна экраны иногда переподключаются позже
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.scheduleApply()
        }
    }

    /// Экраны переподключаются не мгновенно — даём системе устаканиться
    private func scheduleApply() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.applyScheduled = false
            self?.apply()
        }
    }

    func apply() {
        let target = choice == .window ? nil : Self.targetScreen(for: choice)
        if let target { onStageScreen?(target) }
        guard live else {
            hide()
            return
        }
        if choice == .window {
            showTestWindow()
            return
        }
        guard let screen = target else {
            if currentTarget != nil { Log.info("Экран для трансляции не найден — жду подключения") }
            hide()
            return
        }
        showFullscreen(on: screen)
    }

    private func hide() {
        window?.orderOut(nil)
        currentTarget = nil
        currentScreen = nil
    }

    private func makeWindow(test: Bool) -> NSWindow {
        if let window, windowIsTest == test { return window }
        window?.orderOut(nil)
        let view = OutputView(engine: engine)
        let w: NSWindow
        if test {
            w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
                         styleMask: [.titled, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Output (test window)"
            w.setFrameAutosaveName("TestOutputWindow")
            // Обычное окно, не поверх всех: иначе закрывает окна подтверждения
        } else {
            w = OutputWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            // Выше строки меню, Dock и уведомлений
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            w.hasShadow = false
            w.isOpaque = true
        }
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.backgroundColor = .black
        w.contentView = view
        view.attach()
        window = w
        windowIsTest = test
        return w
    }

    private func showTestWindow() {
        let w = makeWindow(test: true)
        if !w.isVisible { w.center() }
        w.orderFront(nil)
        currentTarget = "test window"
        currentScreen = nil
    }

    private func showFullscreen(on screen: NSScreen) {
        let w = makeWindow(test: false)
        let name = screen.localizedName
        if w.frame != screen.frame || !w.isVisible {
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            Log.info("Трансляция на экран «\(name)» \(Int(screen.frame.width))×\(Int(screen.frame.height))")
            if Self.hidesPointer { moveCursorAway(from: screen) }
        }
        currentTarget = name
        currentScreen = screen
    }

    static var hidesPointer: Bool { OutputView.hidePointer }

    /// Курсор не должен висеть на экране трансляции
    private func moveCursorAway(from screen: NSScreen) {
        let mouse = NSEvent.mouseLocation
        guard screen.frame.contains(mouse),
              let other = NSScreen.screens.first(where: { $0 != screen }),
              let primary = NSScreen.screens.first else { return }
        // CG-координаты: начало в левом верхнем углу основного экрана
        let center = CGPoint(x: other.frame.midX, y: primary.frame.height - other.frame.midY)
        CGWarpMouseCursorPosition(center)
    }

    // MARK: - Экраны

    static func ref(for screen: NSScreen) -> DisplayRef {
        let id = displayID(screen)
        return DisplayRef(name: screen.localizedName, vendor: CGDisplayVendorNumber(id),
                          model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func targetScreen(for choice: DisplayChoice) -> NSScreen? {
        let screens = NSScreen.screens
        switch choice {
        case .window:
            return nil
        case .firstExternal:
            let externals = screens.filter { CGDisplayIsBuiltin(displayID($0)) == 0 }
            // Несколько внешних (Mac mini с двумя мониторами) — не основной, там окно управления
            if externals.count >= 2 {
                return externals.first { $0 != screens.first } ?? externals.first
            }
            guard let external = externals.first else { return nil }
            // Ноутбук: открытая крышка — внешний; закрытая крышка — внешний единственный, всё равно на него.
            // Настольный Mac с одним монитором — не закрываем его трансляцией (для проверки есть «Window (test)»)
            let hasBuiltin = screens.contains { CGDisplayIsBuiltin(displayID($0)) != 0 }
            return hasBuiltin || isLaptop ? external : nil
        case .specific(let ref):
            let refs = screens.map { ($0, Self.ref(for: $0)) }
            if let exact = refs.first(where: { $0.1 == ref }) { return exact.0 }
            // Серийника у проекторов часто нет — тогда по производителю и модели, потом по имени
            if let model = refs.first(where: { $0.1.vendor == ref.vendor && $0.1.model == ref.model }) { return model.0 }
            return refs.first { $0.1.name == ref.name }?.0
        }
    }

    /// Есть встроенный аккумулятор — значит, ноутбук
    static let isLaptop: Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { source in
            let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return (d?[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
        }
    }()

    static func screenList() -> String {
        NSScreen.screens.map { s in
            "«\(s.localizedName)» \(Int(s.frame.width))×\(Int(s.frame.height))\(CGDisplayIsBuiltin(displayID(s)) != 0 ? " встроенный" : "")"
        }.joined(separator: ", ")
    }
}
