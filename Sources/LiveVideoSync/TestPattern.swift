import AppKit

/// Тестовая сетка для экрана сцены: сетка с координатами, рамка по краю, центр.
/// По ней видно, какая часть картинки реально видна на экране площадки.
enum TestPattern {
    static func image(size: CGSize, title: String, pixelScale: CGFloat = 1) -> CGImage? {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        let image = NSImage(size: NSSize(width: w, height: h), flipped: true) { rect in
            NSColor(white: 0.08, alpha: 1).setFill()
            rect.fill()
            let W = rect.width, H = rect.height

            // Мелкая сетка каждые 50 px, крупная — каждые 100 px с подписями
            for step in [50.0, 100.0] {
                (step == 100 ? NSColor(white: 0.45, alpha: 1) : NSColor(white: 0.22, alpha: 1)).setStroke()
                let path = NSBezierPath()
                path.lineWidth = 1
                var x = 0.0
                while x <= W { path.move(to: NSPoint(x: x + 0.5, y: 0)); path.line(to: NSPoint(x: x + 0.5, y: H)); x += step }
                var y = 0.0
                while y <= H { path.move(to: NSPoint(x: 0, y: y + 0.5)); path.line(to: NSPoint(x: W, y: y + 0.5)); y += step }
                path.stroke()
            }
            let small: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                                                         .foregroundColor: NSColor(white: 0.75, alpha: 1)]
            var x = 100.0
            while x < W { ("\(Int(x * pixelScale))" as NSString).draw(at: NSPoint(x: x + 4, y: H / 2 + 4), withAttributes: small); x += 100 }
            var y = 100.0
            while y < H { ("\(Int(y * pixelScale))" as NSString).draw(at: NSPoint(x: W / 2 + 4, y: y + 2), withAttributes: small); y += 100 }

            // Центр
            NSColor.systemYellow.setStroke()
            let cross = NSBezierPath()
            cross.lineWidth = 2
            cross.move(to: NSPoint(x: W / 2, y: 0)); cross.line(to: NSPoint(x: W / 2, y: H))
            cross.move(to: NSPoint(x: 0, y: H / 2)); cross.line(to: NSPoint(x: W, y: H / 2))
            cross.stroke()
            NSBezierPath(ovalIn: NSRect(x: W / 2 - 60, y: H / 2 - 60, width: 120, height: 120)).stroke()

            // Рамка по краю экрана — если её не видно, край картинки обрезан
            NSColor.systemRed.setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: 3, dy: 3))
            border.lineWidth = 6
            border.stroke()

            let big: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(18, H / 24), weight: .bold),
                                                       .foregroundColor: NSColor.white]
            let title = (title.isEmpty ? "\(Int(W)) × \(Int(H)) px" : title) as NSString
            let ts = title.size(withAttributes: big)
            title.draw(at: NSPoint(x: (W - ts.width) / 2, y: H / 2 - ts.height - 70), withAttributes: big)
            let corner: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                                                          .foregroundColor: NSColor.systemRed]
            ("↖ top left" as NSString).draw(at: NSPoint(x: 16, y: 14), withAttributes: corner)
            let tr = "top right ↗" as NSString
            tr.draw(at: NSPoint(x: W - tr.size(withAttributes: corner).width - 16, y: 14), withAttributes: corner)
            ("↙ bottom left" as NSString).draw(at: NSPoint(x: 16, y: H - 34), withAttributes: corner)
            let br = "bottom right ↘" as NSString
            br.draw(at: NSPoint(x: W - br.size(withAttributes: corner).width - 16, y: H - 34), withAttributes: corner)
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
