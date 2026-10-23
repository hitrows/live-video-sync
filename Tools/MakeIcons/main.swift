import AppKit
import CoreGraphics

// Иконки программ в стиле macOS: «сквиркл» 824×824 на холсте 1024, мягкий градиент и тень.
//   build/make-icons <папка Resources>
// Пишет Resources/AppIcon.icns (плеер) и Resources/MIDILink/MIDILink.icns.

typealias Draw = (CGContext) -> Void

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// Плашка macOS: тень, градиент, тонкий светлый край сверху. Содержимое рисуется в координатах 1024, начало — левый верхний угол.
func plate(_ ctx: CGContext, top: UInt32, bottom: UInt32, content: Draw) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(path)
    ctx.setFillColor(color(bottom))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    linear(ctx, [color(top), color(bottom)], from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
    content(ctx)
    ctx.restoreGState()

    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.12))
    ctx.setLineWidth(4)
    ctx.strokePath()
}

func roundedRect(_ ctx: CGContext, _ r: CGRect, _ radius: CGFloat) {
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
}

func triangle(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint, round: CGFloat) {
    ctx.move(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
    ctx.addArc(tangent1End: b, tangent2End: c, radius: round)
    ctx.addArc(tangent1End: c, tangent2End: a, radius: round)
    ctx.addArc(tangent1End: a, tangent2End: b, radius: round)
    ctx.closePath()
}

// Плеер: экран на сцене и два прожектора
let playerIcon: Draw = { ctx in
    plate(ctx, top: 0x45443F, bottom: 0x1C1C1B) { ctx in
        // Лучи прожекторов: от приборов на полу расширяются к экрану и гаснут
        for side in [-1.0, 1.0] {
            let source = CGPoint(x: 512 + side * 250, y: 770)
            ctx.saveGState()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: source.x - 22, y: source.y))
            path.addLine(to: CGPoint(x: source.x + 22, y: source.y))
            path.addLine(to: CGPoint(x: 512 + side * (side > 0 ? 40 : 40), y: 540))
            path.addLine(to: CGPoint(x: 512 + side * 270, y: 540))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.clip()
            linear(ctx, [color(0xFAC775, 0.9), color(0xEF9F27, 0.12)], from: CGPoint(x: source.x, y: source.y), to: CGPoint(x: 512, y: 540))
            ctx.restoreGState()
            // Прибор: корпус и светящееся стекло
            ctx.saveGState()
            ctx.translateBy(x: source.x, y: source.y + 18)
            ctx.rotate(by: side * -0.55)
            ctx.setFillColor(color(0x5F5E5A))
            roundedRect(ctx, CGRect(x: -46, y: -20, width: 92, height: 62), 16)
            ctx.fillPath()
            ctx.setFillColor(color(0xFFF3D6))
            ctx.fillEllipse(in: CGRect(x: -34, y: -26, width: 68, height: 22))
            ctx.restoreGState()
        }
        // Пол сцены
        ctx.setFillColor(color(0x888780))
        roundedRect(ctx, CGRect(x: 200, y: 836, width: 624, height: 20), 10)
        ctx.fillPath()

        // Экран с тенью и светлым градиентом
        let screen = CGRect(x: 232, y: 214, width: 560, height: 352)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.5))
        roundedRect(ctx, screen, 40)
        ctx.setFillColor(color(0xFAEEDA))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        roundedRect(ctx, screen, 40)
        ctx.clip()
        linear(ctx, [color(0xFFF8EC), color(0xF5DDB4)], from: CGPoint(x: 512, y: 214), to: CGPoint(x: 512, y: 566))
        ctx.restoreGState()

        // Play
        triangle(ctx, CGPoint(x: 452, y: 300), CGPoint(x: 600, y: 390), CGPoint(x: 452, y: 480), round: 22)
        ctx.setFillColor(color(0x633806))
        ctx.fillPath()
    }
}

// MIDI Link: MIDI-разъём и дуги Wi-Fi
let linkIcon: Draw = { ctx in
    plate(ctx, top: 0x185FA5, bottom: 0x042C53) { ctx in
        ctx.setStrokeColor(color(0xB5D4F4))
        ctx.setLineCap(.round)
        ctx.setLineWidth(46)
        for (radius, alpha) in [(300.0, 0.55), (205.0, 0.9)] {
            ctx.setStrokeColor(color(0xB5D4F4, alpha))
            ctx.addArc(center: CGPoint(x: 512, y: 560), radius: radius, startAngle: .pi * 1.25, endAngle: .pi * 1.75, clockwise: false)
            ctx.strokePath()
        }
        // Разъём
        let center = CGPoint(x: 512, y: 640)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: color(0x000000, 0.45))
        ctx.setFillColor(color(0xE6F1FB))
        ctx.fillEllipse(in: CGRect(x: center.x - 190, y: center.y - 190, width: 380, height: 380))
        ctx.restoreGState()
        ctx.setStrokeColor(color(0x85B7EB))
        ctx.setLineWidth(14)
        ctx.strokeEllipse(in: CGRect(x: center.x - 150, y: center.y - 150, width: 300, height: 300))
        ctx.setFillColor(color(0x042C53))
        roundedRect(ctx, CGRect(x: center.x - 34, y: center.y - 176, width: 68, height: 44), 12)
        ctx.fillPath()
        // Пять контактов по дуге снизу, как у DIN
        for angle in [180.0, 135.0, 90.0, 45.0, 0.0] {
            let a = angle * .pi / 180
            let p = CGPoint(x: center.x + 100 * cos(a), y: center.y + 100 * sin(a) * 0.95 + 10)
            ctx.fillEllipse(in: CGRect(x: p.x - 26, y: p.y - 26, width: 52, height: 52))
        }
    }
}

func render(_ draw: Draw, size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let k = CGFloat(size) / 1024
    // Координаты рисунка — от левого верхнего угла
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: k, y: -k)
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

func makeIcns(_ draw: Draw, to url: URL) throws {
    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try render(draw, size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        try render(draw, size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", iconset.path, "-o", url.path]
    try p.run()
    p.waitUntilExit()
    try? FileManager.default.removeItem(at: iconset)
    guard p.terminationStatus == 0 else { throw NSError(domain: "iconutil", code: Int(p.terminationStatus)) }
    // Превью 1024 рядом — посмотреть глазами
    try render(draw, size: 1024).write(to: url.deletingPathExtension().appendingPathExtension("png"))
    print(url.path)
}

let resources = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
try makeIcns(playerIcon, to: resources.appendingPathComponent("AppIcon.icns"))
try makeIcns(linkIcon, to: resources.appendingPathComponent("MIDILink/MIDILink.icns"))
