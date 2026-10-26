import AppKit
import SwiftUI

/// Screen Fit — подгонка под экран площадки, как экранные элементы Final Cut.
/// Большое превью = холст экрана сцены; ручки Transform / Crop / Distort; справа точные числа.
struct ScreenFitView: View {
    @ObservedObject var show: Show
    @State private var tool: Tool = .transform
    @State private var mirror: PreviewMirror?
    @State private var naming: NameRequest?
    @State private var name = ""
    @State private var deleting = false

    enum Tool: Hashable { case transform, crop, distort }

    enum NameRequest: Identifiable {
        case save, rename(UUID)
        var id: String {
            switch self {
            case .save: return "save"
            case .rename(let id): return id.uuidString
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Banners(show: show)
                controls
                if let mirror {
                    FitCanvas(show: show, mirror: mirror, tool: tool)
                }
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            Inspector(show: show)
                .frame(width: 280)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { if mirror == nil { mirror = PreviewMirror(engine: show.engine) } }
        .alert(nameTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Venue", text: $name)
            Button(nameButton) {
                switch naming {
                case .save: show.savePreset(named: name)
                case .rename(let id): show.renamePreset(id, to: name)
                case nil: break
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete preset “\(show.venuePresetName ?? "")”?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { if let id = show.settings.venuePreset { show.deletePreset(id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The stage screen keeps the current fit.")
        }
    }

    private var nameTitle: String {
        if case .rename = naming { return "Rename Preset" }
        return "Save as Preset"
    }

    private var nameButton: String {
        if case .rename = naming { return "Rename" }
        return "Save"
    }

    private var hint: String {
        switch tool {
        case .transform: return "Drag the video to move · corners to scale (Shift keeps proportions) · handle on the arm to rotate · ← → ↑ ↓ 1 px, Shift 10 px · edges snap, hold ⌘ to turn it off"
        case .crop: return "Drag the edges to cut off what the venue screen can’t show"
        case .distort: return "Drag the corners to fit a projector that hits the screen at an angle"
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Tool", selection: $tool) {
                Text("Transform").tag(Tool.transform)
                Text("Crop").tag(Tool.crop)
                Text("Distort").tag(Tool.distort)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Toggle("Test Pattern", isOn: $show.testPattern)
                .toggleStyle(.button)
                .help("Show a grid with a red border on the stage screen (⌘T)")
            Menu(show.venuePresetName ?? "No Preset") {
                ForEach(show.settings.venuePresets) { preset in
                    Button {
                        show.choosePreset(preset.id)
                    } label: {
                        if preset.id == show.settings.venuePreset {
                            Label(preset.name, systemImage: "checkmark")
                        } else {
                            Text(preset.name)
                        }
                    }
                }
                if !show.settings.venuePresets.isEmpty { Divider() }
                Button("Save as Preset…") {
                    name = ""
                    naming = .save
                }
                Button("Rename Preset…") {
                    name = show.venuePresetName ?? ""
                    if let id = show.settings.venuePreset { naming = .rename(id) }
                }
                .disabled(show.settings.venuePreset == nil)
                Button("Delete Preset…") { deleting = true }
                    .disabled(show.settings.venuePreset == nil)
            }
            .fixedSize()
            .help("Venue presets")
            Button("Reset All") { show.settings.screenFit = ScreenFit() }
                .disabled(show.settings.screenFit == ScreenFit())
        }
    }
}

// MARK: - Холст

private struct FitCanvas: View {
    @ObservedObject var show: Show
    let mirror: PreviewMirror
    let tool: ScreenFitView.Tool
    @State private var start: ScreenFit?
    @FocusState private var focused: Bool

    private var size: CGSize { show.engine.rootLayer.bounds.size }

    var body: some View {
        GeometryReader { geo in
            let k = min(geo.size.width / max(1, size.width), geo.size.height / max(1, size.height))
            let frame = CGSize(width: size.width * k, height: size.height * k)
            ZStack(alignment: .topLeading) {
                MirrorView(mirror: mirror)
                    .frame(width: frame.width, height: frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                grid(k: k)
                handles(k: k)
            }
            .frame(width: frame.width, height: frame.height)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator).allowsHitTesting(false))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(size.width / max(1, size.height), contentMode: .fit)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            let step = press.modifiers.contains(.shift) ? 10.0 : 1.0
            var fit = show.settings.screenFit
            switch press.key {
            case .leftArrow: fit.positionX -= step
            case .rightArrow: fit.positionX += step
            case .upArrow: fit.positionY += step
            default: fit.positionY -= step
            }
            show.settings.screenFit = fit
            return .handled
        }
        .onTapGesture { focused = true }
    }

    /// Лёгкое примагничивание; ⌘ — без него (как в Keynote)
    private var snapping: Bool { !NSEvent.modifierFlags.contains(.command) }

    /// 8 точек на экране — в пикселях холста
    private func snapDistance(_ k: CGFloat) -> Double { Double(8 / max(k, 0.01)) }

    /// Насколько сдвинуть, чтобы ближайшая из точек легла на ближайшую цель (nil — далеко)
    static func snapDelta(_ points: [Double], to targets: [Double], within t: Double) -> Double? {
        var best: Double?
        for p in points {
            for target in targets where abs(target - p) <= t {
                if best == nil || abs(target - p) < abs(best!) { best = target - p }
            }
        }
        return best
    }

    /// Холст (Y вверх) → вид (Y вниз)
    private func view(_ p: (x: Double, y: Double), _ k: CGFloat) -> CGPoint {
        CGPoint(x: p.x * k, y: (size.height - p.y) * k)
    }

    private func canvas(_ p: CGPoint, _ k: CGFloat) -> (x: Double, y: Double) {
        (Double(p.x / k), Double(size.height - p.y / k))
    }

    /// Сетка с подписями каждые 10 %
    private func grid(k: CGFloat) -> some View {
        Canvas { ctx, sz in
            for i in 1..<10 {
                let x = sz.width * CGFloat(i) / 10, y = sz.height * CGFloat(i) / 10
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: sz.height))
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: sz.width, y: y))
                ctx.stroke(p, with: .color(.white.opacity(i == 5 ? 0.22 : 0.08)), lineWidth: 1)
            }
            ctx.draw(Text("\(Int(size.width))×\(Int(size.height))").font(.caption2).foregroundColor(.white.opacity(0.5)),
                     at: CGPoint(x: sz.width - 6, y: 6), anchor: .topTrailing)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func handles(k: CGFloat) -> some View {
        let fit = show.settings.screenFit
        let w = Double(size.width), h = Double(size.height)
        let quad = fit.quad(width: w, height: h).map { view($0, k) }
        let outline = Path { p in
            p.addLines(quad)
            p.closeSubpath()
        }
        ZStack(alignment: .topLeading) {
            outline.fill(Color.white.opacity(0.001))
                .contentShape(outline)
                .gesture(tool == .transform ? moveGesture(k: k) : nil)
            outline.stroke(Color.accentColor, lineWidth: 1.5)
                .allowsHitTesting(false)
            switch tool {
            case .transform: transformHandles(fit: fit, quad: quad, k: k)
            case .crop: cropHandles(fit: fit, quad: quad, k: k)
            case .distort: distortHandles(quad: quad, k: k)
            }
        }
    }

    // MARK: Transform

    private func moveGesture(k: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { g in
                let s = start ?? show.settings.screenFit
                if start == nil { start = s }
                var fit = s
                if !fit.transformOn { fit.transformOn = true }
                fit.positionX = (s.positionX + Double(g.translation.width / k)).rounded()
                fit.positionY = (s.positionY - Double(g.translation.height / k)).rounded()
                if snapping {
                    // Края картинки — к краям экрана, центр — к центру
                    let w = Double(size.width), h = Double(size.height), t = snapDistance(k)
                    let q = fit.quad(width: w, height: h)
                    let xs = q.map(\.x), ys = q.map(\.y)
                    let (minX, maxX, minY, maxY) = (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
                    if let dx = Self.snapDelta([minX, maxX, (minX + maxX) / 2], to: [0, w, w / 2], within: t) { fit.positionX += dx }
                    if let dy = Self.snapDelta([minY, maxY, (minY + maxY) / 2], to: [0, h, h / 2], within: t) { fit.positionY += dy }
                }
                show.settings.screenFit = fit
                focused = true
            }
            .onEnded { _ in start = nil }
    }

    @ViewBuilder
    private func transformHandles(fit: ScreenFit, quad: [CGPoint], k: CGFloat) -> some View {
        // Углы: нижний левый, нижний правый, верхний правый, верхний левый (как в quad)
        let signs: [(Double, Double)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        ForEach(0..<4, id: \.self) { i in
            HandleDot()
                .position(quad[i])
                .gesture(scaleGesture(sx: signs[i].0, sy: signs[i].1, k: k))
        }
        ForEach(0..<4, id: \.self) { i in
            let a = quad[i], b = quad[(i + 1) % 4]
            // Стороны: низ (sy), право (sx), верх (sy), лево (sx)
            let axis: (Double, Double) = i % 2 == 0 ? (0, i == 0 ? -1 : 1) : (i == 1 ? 1 : -1, 0)
            HandleDot()
                .position(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
                .gesture(scaleGesture(sx: axis.0, sy: axis.1, k: k))
        }
        let e = fit.effective
        let w = Double(size.width), h = Double(size.height)
        let center = view((w / 2 + e.anchorX + e.positionX, h / 2 + e.anchorY + e.positionY), k)
        let angle = e.rotation * .pi / 180
        let arm = CGPoint(x: center.x + 44 * cos(angle), y: center.y - 44 * sin(angle))
        Path { p in
            p.move(to: center)
            p.addLine(to: arm)
        }
        .stroke(Color.white, lineWidth: 1.5)
        .allowsHitTesting(false)
        Circle().strokeBorder(.white, lineWidth: 1.5)
            .frame(width: 12, height: 12)
            .position(center)
            .allowsHitTesting(false)
        HandleDot()
            .position(arm)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    var fit = show.settings.screenFit
                    fit.transformOn = true
                    let dx = Double(g.location.x - center.x), dy = Double(center.y - g.location.y)
                    var deg = atan2(dy, dx) * 180 / .pi
                    if NSEvent.modifierFlags.contains(.shift) { deg = (deg / 15).rounded() * 15 }
                    fit.rotation = (deg * 10).rounded() / 10
                    show.settings.screenFit = fit
                })
    }

    /// Ручка масштаба: sx, sy — какие оси тянет и в какую сторону (−1, 0, 1)
    private func scaleGesture(sx: Double, sy: Double, k: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let s = start ?? show.settings.screenFit
                if start == nil { start = s }
                var fit = s
                fit.transformOn = true
                let e = s.effective
                let w = Double(size.width), h = Double(size.height)
                // Указатель → в повёрнутую систему кадра относительно точки привязки
                let p = canvas(g.location, k)
                let ax = w / 2 + e.anchorX + e.positionX, ay = h / 2 + e.anchorY + e.positionY
                let a = -e.rotation * .pi / 180
                let qx = p.x - ax, qy = p.y - ay
                let lx = qx * cos(a) - qy * sin(a), ly = qx * sin(a) + qy * cos(a)
                let all = max(0.0001, e.scale / 100)
                // Край кадра относительно точки привязки (без масштаба)
                let ex = sx > 0 ? w / 2 - e.anchorX : -(w / 2 + e.anchorX)
                let ey = sy > 0 ? h / 2 - e.anchorY : -(h / 2 + e.anchorY)
                var newX = sx != 0 && abs(ex) > 0.5 ? max(1, lx / ex / all * 100) : e.scaleX
                var newY = sy != 0 && abs(ey) > 0.5 ? max(1, ly / ey / all * 100) : e.scaleY
                if NSEvent.modifierFlags.contains(.shift) || sx == 0 || sy == 0 {
                    if sx != 0, sy != 0 {
                        // Shift — пропорционально: общий масштаб
                        let ratio = max(newX / max(0.01, e.scaleX), newY / max(0.01, e.scaleY))
                        fit.scale = (max(1, e.scale * ratio) * 10).rounded() / 10
                        newX = e.scaleX
                        newY = e.scaleY
                    }
                }
                fit.scaleX = (newX * 10).rounded() / 10
                fit.scaleY = (newY * 10).rounded() / 10
                if snapping {
                    // Масштаб липнет к 100 %
                    for kp in [\ScreenFit.scale, \ScreenFit.scaleX, \ScreenFit.scaleY] where abs(fit[keyPath: kp] - 100) < 2 {
                        fit[keyPath: kp] = 100
                    }
                }
                show.settings.screenFit = fit
            }
            .onEnded { _ in start = nil }
    }

    // MARK: Crop

    @ViewBuilder
    private func cropHandles(fit: ScreenFit, quad: [CGPoint], k: CGFloat) -> some View {
        // Стороны: низ, право, верх, лево
        ForEach(0..<4, id: \.self) { i in
            let a = quad[i], b = quad[(i + 1) % 4]
            CropBar(vertical: i % 2 == 1)
                .position(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
                .rotationEffect(.radians(-fit.effective.rotation * .pi / 180))
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        var fit = show.settings.screenFit
                        fit.cropOn = true
                        let w = Double(size.width), h = Double(size.height)
                        let local = fit.invertTransform(canvas(g.location, k), width: w, height: h)
                        switch i {
                        case 0: fit.cropBottom = min(max(0, local.y), h - fit.cropTop - 10).rounded()
                        case 1: fit.cropRight = min(max(0, w - local.x), w - fit.cropLeft - 10).rounded()
                        case 2: fit.cropTop = min(max(0, h - local.y), h - fit.cropBottom - 10).rounded()
                        default: fit.cropLeft = min(max(0, local.x), w - fit.cropRight - 10).rounded()
                        }
                        if snapping {
                            let t = snapDistance(k)
                            for kp in [\ScreenFit.cropLeft, \ScreenFit.cropRight, \ScreenFit.cropTop, \ScreenFit.cropBottom]
                            where fit[keyPath: kp] < t { fit[keyPath: kp] = 0 }
                        }
                        show.settings.screenFit = fit
                    })
        }
    }

    // MARK: Distort

    @ViewBuilder
    private func distortHandles(quad: [CGPoint], k: CGFloat) -> some View {
        ForEach(0..<4, id: \.self) { i in
            HandleDot(square: true)
                .position(quad[i])
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let s = start ?? show.settings.screenFit
                        if start == nil { start = s }
                        var fit = s
                        fit.distortOn = true
                        let dx = Double(g.translation.width / k), dy = -Double(g.translation.height / k)
                        func moved(_ c: ScreenFit.Corner) -> ScreenFit.Corner { .init(x: (c.x + dx).rounded(), y: (c.y + dy).rounded()) }
                        switch i {
                        case 0: fit.bottomLeft = moved(s.bottomLeft)
                        case 1: fit.bottomRight = moved(s.bottomRight)
                        case 2: fit.topRight = moved(s.topRight)
                        default: fit.topLeft = moved(s.topLeft)
                        }
                        if snapping {
                            // Угол липнет к краям и углам экрана
                            let w = Double(size.width), h = Double(size.height), t = snapDistance(k)
                            let corner = fit.quad(width: w, height: h)[i]
                            let sx = Self.snapDelta([corner.x], to: [0, w], within: t) ?? 0
                            let sy = Self.snapDelta([corner.y], to: [0, h], within: t) ?? 0
                            func nudge(_ c: inout ScreenFit.Corner) { c.x += sx; c.y += sy }
                            switch i {
                            case 0: nudge(&fit.bottomLeft)
                            case 1: nudge(&fit.bottomRight)
                            case 2: nudge(&fit.topRight)
                            default: nudge(&fit.topLeft)
                            }
                        }
                        show.settings.screenFit = fit
                    }
                    .onEnded { _ in start = nil })
        }
    }
}

private struct HandleDot: View {
    var square = false

    var body: some View {
        Group {
            if square {
                RoundedRectangle(cornerRadius: 2).fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor, lineWidth: 1.5))
            } else {
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
            }
        }
        .frame(width: 10, height: 10)
        .padding(6)
        .contentShape(Rectangle())
    }
}

private struct CropBar: View {
    let vertical: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.white)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor, lineWidth: 1.5))
            .frame(width: vertical ? 6 : 28, height: vertical ? 28 : 6)
            .padding(6)
            .contentShape(Rectangle())
    }
}

/// Слои превью в SwiftUI
private struct MirrorView: NSViewRepresentable {
    let mirror: PreviewMirror

    final class View: NSView {
        let mirror: PreviewMirror
        private var timer: Timer?
        init(mirror: PreviewMirror) {
            self.mirror = mirror
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
            layer?.addSublayer(mirror.rootLayer)
            // Своё превью — своя синхронизация, 60 раз в секунду
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.mirror.sync() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        required init?(coder: NSCoder) { fatalError() }
        deinit { timer?.invalidate() }
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

// MARK: - Инспектор

private struct Inspector: View {
    @ObservedObject var show: Show

    private var w: Double { Double(show.engine.rootLayer.bounds.width) }
    private var h: Double { Double(show.engine.rootLayer.bounds.height) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                group("Transform", on: $show.settings.screenFit.transformOn, reset: { show.settings.screenFit.resetTransform() }) {
                    pairRow("Position", $show.settings.screenFit.positionX, $show.settings.screenFit.positionY, unit: "px")
                    numberRow("Rotation", $show.settings.screenFit.rotation, unit: "°")
                    sliderRow("Scale (All)", $show.settings.screenFit.scale, range: 1...400, unit: "%")
                    sliderRow("Scale X", $show.settings.screenFit.scaleX, range: 1...400, unit: "%")
                    sliderRow("Scale Y", $show.settings.screenFit.scaleY, range: 1...400, unit: "%")
                    pairRow("Anchor", $show.settings.screenFit.anchorX, $show.settings.screenFit.anchorY, unit: "px")
                }
                group("Crop", on: $show.settings.screenFit.cropOn, reset: { show.settings.screenFit.resetCrop() }) {
                    sliderRow("Left", $show.settings.screenFit.cropLeft, range: 0...max(1, w / 2), unit: "px")
                    sliderRow("Right", $show.settings.screenFit.cropRight, range: 0...max(1, w / 2), unit: "px")
                    sliderRow("Top", $show.settings.screenFit.cropTop, range: 0...max(1, h / 2), unit: "px")
                    sliderRow("Bottom", $show.settings.screenFit.cropBottom, range: 0...max(1, h / 2), unit: "px")
                }
                group("Distort", on: $show.settings.screenFit.distortOn, reset: { show.settings.screenFit.resetDistort() }) {
                    pairRow("Top Left", $show.settings.screenFit.topLeft.x, $show.settings.screenFit.topLeft.y)
                    pairRow("Top Right", $show.settings.screenFit.topRight.x, $show.settings.screenFit.topRight.y)
                    pairRow("Bottom Left", $show.settings.screenFit.bottomLeft.x, $show.settings.screenFit.bottomLeft.y)
                    pairRow("Bottom Right", $show.settings.screenFit.bottomRight.x, $show.settings.screenFit.bottomRight.y)
                }
            }
        }
    }

    private func group<Content: View>(_ title: String, on: Binding<Bool>, reset: @escaping () -> Void,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(title, isOn: on)
                    .toggleStyle(.checkbox)
                    .font(.headline)
                Spacer()
                Button(action: reset) { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("Reset \(title)")
            }
            Divider()
            content()
                .disabled(!on.wrappedValue)
        }
    }

    private func field(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(0...1)))
            .multilineTextAlignment(.trailing)
            .frame(width: 58)
            .labelsHidden()
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
    }

    private func pairRow(_ title: String, _ x: Binding<Double>, _ y: Binding<Double>, unit: String? = nil) -> some View {
        HStack(spacing: 6) {
            label(title)
            Text("X").font(.caption).foregroundStyle(.tertiary)
            field(x)
            Text("Y").font(.caption).foregroundStyle(.tertiary)
            field(y)
            if let unit { Text(unit).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func numberRow(_ title: String, _ value: Binding<Double>, unit: String) -> some View {
        HStack(spacing: 6) {
            label(title)
            Stepper("", value: value, step: 0.5).labelsHidden()
            field(value)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sliderRow(_ title: String, _ value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack(spacing: 6) {
            label(title)
            Slider(value: Binding(get: { min(max(value.wrappedValue, range.lowerBound), range.upperBound) },
                                  set: { value.wrappedValue = ($0 * 10).rounded() / 10 }), in: range)
                .controlSize(.small)
            field(value)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }
}
