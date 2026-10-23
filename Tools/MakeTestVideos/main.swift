import AVFoundation
import AppKit
import CoreText

// Тестовые видео 1040×640, 25 к/с, H.264: «NN_Test Song.mp4» и «logo.mp4».
// На каждом кадре — номер песни, время от начала видео, номер кадра и бегущая полоса.
//   build/make-test-videos <папка> [песен=12] [длина=20]

let width = 1040, height = 640, fps: Int32 = 25

func makeVideo(url: URL, seconds: Double, draw: (CGContext, Int, Double) -> Void) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 4_000_000,
            AVVideoMaxKeyFrameIntervalKey: Int(fps),      // ключевой кадр раз в секунду — быстрая перемотка
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let frames = Int(seconds * Double(fps))
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        guard let pool = adaptor.pixelBufferPool else { throw NSError(domain: "pool", code: 1) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw NSError(domain: "buffer", code: 2) }
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        draw(ctx, frame, Double(frame) / Double(fps))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if writer.status != .completed { throw writer.error ?? NSError(domain: "writer", code: 3) }
}

func text(_ ctx: CGContext, _ s: String, size: CGFloat, x: CGFloat, y: CGFloat, color: CGColor = .white, center: Bool = false) {
    let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
    let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    let line = CTLineCreateWithAttributedString(attr)
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textPosition = CGPoint(x: center ? x - CGFloat(w) / 2 : x, y: y)
    CTLineDraw(line, ctx)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Использование: make-test-videos <папка> [песен=12] [длина=20]")
    exit(1)
}
let folder = URL(fileURLWithPath: args[1])
let count = args.count > 2 ? Int(args[2]) ?? 12 : 12
let baseLength = args.count > 3 ? Double(args[3]) ?? 20 : 20
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

// Логотип: круг делает ровно один оборот за 4 с — шов цикла не виден
let logoLength = 4.0
try makeVideo(url: folder.appendingPathComponent("logo.mp4"), seconds: logoLength) { ctx, frame, t in
    ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let angle = t / logoLength * 2 * .pi
    ctx.setFillColor(CGColor(red: 0.9, green: 0.75, blue: 0.2, alpha: 1))
    let cx = CGFloat(width) / 2 + 180 * CGFloat(cos(angle)), cy = CGFloat(height) / 2 + 180 * CGFloat(sin(angle))
    ctx.fillEllipse(in: CGRect(x: cx - 30, y: cy - 30, width: 60, height: 60))
    text(ctx, "SILA", size: 120, x: CGFloat(width) / 2, y: CGFloat(height) / 2 - 40, center: true)
    text(ctx, "LOGO LOOP", size: 24, x: CGFloat(width) / 2, y: 40, color: CGColor(gray: 0.6, alpha: 1), center: true)
}
print("logo.mp4")

for n in 1...count {
    // Разная длина и цвет, чтобы песни было легко различить
    let length = baseLength + Double((n * 7) % 11)
    let hue = CGFloat(n) / CGFloat(count)
    let bg = NSColor(hue: hue, saturation: 0.55, brightness: 0.45, alpha: 1).cgColor
    let name = String(format: "%02d_Test Song %d.mp4", n, n)
    try makeVideo(url: folder.appendingPathComponent(name), seconds: length) { ctx, frame, t in
        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Рамка по краю — видно обрезку в режимах масштаба
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(6)
        ctx.stroke(CGRect(x: 3, y: 3, width: width - 6, height: height - 6))
        text(ctx, String(format: "SONG %02d", n), size: 110, x: CGFloat(width) / 2, y: 380, center: true)
        text(ctx, String(format: "%02d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)), size: 90,
             x: CGFloat(width) / 2, y: 240, center: true)
        text(ctx, "frame \(frame)   length \(Int(length)) s", size: 26, x: CGFloat(width) / 2, y: 170,
             color: CGColor(gray: 0.85, alpha: 1), center: true)
        // Полоса пробегает экран за секунду — рывки сразу заметны
        let x = CGFloat(t.truncatingRemainder(dividingBy: 1)) * CGFloat(width - 60)
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: x, y: 60, width: 60, height: 40))
        // Последние 2 с — предупреждение о конце
        if length - t < 2 {
            text(ctx, "END", size: 40, x: CGFloat(width) / 2, y: 520, color: CGColor(red: 1, green: 0.3, blue: 0.3, alpha: 1), center: true)
        }
    }
    print(name)
}
print("Готово: \(folder.path)")
