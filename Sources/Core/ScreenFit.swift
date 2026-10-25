import Foundation

/// Подгонка выхода под экран площадки (как экранные элементы Final Cut): Transform, Crop, Distort.
/// Применяется ко всему, что идёт на экран сцены. Единицы — пиксели экрана сцены,
/// координаты как в Final Cut: начало в центре, Y вверх, поворот против часовой стрелки.
struct ScreenFit: Codable, Equatable {
    struct Corner: Codable, Equatable {
        var x = 0.0
        var y = 0.0
    }

    var transformOn = true
    var positionX = 0.0
    var positionY = 0.0
    /// Градусы, против часовой стрелки
    var rotation = 0.0
    /// Проценты
    var scale = 100.0
    var scaleX = 100.0
    var scaleY = 100.0
    /// Точка, вокруг которой масштаб и поворот (от центра кадра)
    var anchorX = 0.0
    var anchorY = 0.0

    var cropOn = true
    var cropLeft = 0.0
    var cropRight = 0.0
    var cropTop = 0.0
    var cropBottom = 0.0

    var distortOn = true
    var topLeft = Corner()
    var topRight = Corner()
    var bottomRight = Corner()
    var bottomLeft = Corner()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScreenFit()
        func v<T: Decodable>(_ key: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? def }
        transformOn = v(.transformOn, d.transformOn)
        positionX = v(.positionX, 0); positionY = v(.positionY, 0); rotation = v(.rotation, 0)
        scale = v(.scale, 100); scaleX = v(.scaleX, 100); scaleY = v(.scaleY, 100)
        anchorX = v(.anchorX, 0); anchorY = v(.anchorY, 0)
        cropOn = v(.cropOn, true)
        cropLeft = v(.cropLeft, 0); cropRight = v(.cropRight, 0); cropTop = v(.cropTop, 0); cropBottom = v(.cropBottom, 0)
        distortOn = v(.distortOn, true)
        topLeft = v(.topLeft, Corner()); topRight = v(.topRight, Corner())
        bottomRight = v(.bottomRight, Corner()); bottomLeft = v(.bottomLeft, Corner())
    }

    var isIdentity: Bool { self == ScreenFit() || effective == ScreenFit().effective }

    /// С учётом выключенных групп
    var effective: ScreenFit {
        var f = self
        let d = ScreenFit()
        if !transformOn {
            f.positionX = d.positionX; f.positionY = d.positionY; f.rotation = d.rotation
            f.scale = d.scale; f.scaleX = d.scaleX; f.scaleY = d.scaleY; f.anchorX = d.anchorX; f.anchorY = d.anchorY
        }
        if !cropOn { f.cropLeft = 0; f.cropRight = 0; f.cropTop = 0; f.cropBottom = 0 }
        if !distortOn { f.topLeft = Corner(); f.topRight = Corner(); f.bottomRight = Corner(); f.bottomLeft = Corner() }
        f.transformOn = true; f.cropOn = true; f.distortOn = true
        return f
    }

    mutating func resetTransform() {
        let d = ScreenFit()
        positionX = d.positionX; positionY = d.positionY; rotation = d.rotation
        scale = d.scale; scaleX = d.scaleX; scaleY = d.scaleY; anchorX = d.anchorX; anchorY = d.anchorY
    }

    mutating func resetCrop() {
        cropLeft = 0; cropRight = 0; cropTop = 0; cropBottom = 0
    }

    mutating func resetDistort() {
        topLeft = Corner(); topRight = Corner(); bottomRight = Corner(); bottomLeft = Corner()
    }

    // MARK: - Геометрия (Y вверх, начало в левом нижнем углу холста W×H, как у Core Animation на Mac)

    /// Видимая часть кадра после Crop — в координатах холста до трансформации
    func cropRect(width w: Double, height h: Double) -> (x: Double, y: Double, w: Double, h: Double) {
        let f = effective
        let l = min(max(0, f.cropLeft), w - 1), r = min(max(0, f.cropRight), w - 1 - l)
        let b = min(max(0, f.cropBottom), h - 1), t = min(max(0, f.cropTop), h - 1 - b)
        return (l, b, w - l - r, h - b - t)
    }

    /// Transform без Distort: точка холста (до подгонки) → точка холста (после)
    func applyTransform(_ p: (x: Double, y: Double), width w: Double, height h: Double) -> (x: Double, y: Double) {
        let f = effective
        let ax = w / 2 + f.anchorX, ay = h / 2 + f.anchorY
        let sx = f.scale / 100 * f.scaleX / 100, sy = f.scale / 100 * f.scaleY / 100
        let a = f.rotation * .pi / 180
        let dx = (p.x - ax) * sx, dy = (p.y - ay) * sy
        return (ax + dx * cos(a) - dy * sin(a) + f.positionX,
                ay + dx * sin(a) + dy * cos(a) + f.positionY)
    }

    /// Обратное к applyTransform (для перетаскивания ручек Crop)
    func invertTransform(_ p: (x: Double, y: Double), width w: Double, height h: Double) -> (x: Double, y: Double) {
        let f = effective
        let ax = w / 2 + f.anchorX, ay = h / 2 + f.anchorY
        let sx = f.scale / 100 * f.scaleX / 100, sy = f.scale / 100 * f.scaleY / 100
        let a = -f.rotation * .pi / 180
        let qx = p.x - f.positionX - ax, qy = p.y - f.positionY - ay
        let rx = qx * cos(a) - qy * sin(a), ry = qx * sin(a) + qy * cos(a)
        return (ax + rx / (sx == 0 ? 1 : sx), ay + ry / (sy == 0 ? 1 : sy))
    }

    /// Углы видимой части на экране сцены: нижний левый, нижний правый, верхний правый, верхний левый
    func quad(width w: Double, height h: Double) -> [(x: Double, y: Double)] {
        let f = effective
        let r = cropRect(width: w, height: h)
        let corners = [(r.x, r.y), (r.x + r.w, r.y), (r.x + r.w, r.y + r.h), (r.x, r.y + r.h)]
        let moved = corners.map { applyTransform($0, width: w, height: h) }
        let offsets = [f.bottomLeft, f.bottomRight, f.topRight, f.topLeft]
        return zip(moved, offsets).map { ($0.x + $1.x, $0.y + $1.y) }
    }

    /// Проективное преобразование (гомография) прямоугольника crop → четырёхугольник quad.
    /// Возвращает 3×3 по строкам [a b c; d e f; g h 1]: x' = (a x + b y + c) / (g x + h y + 1)
    func homography(width w: Double, height h: Double) -> [Double]? {
        let r = cropRect(width: w, height: h)
        let src = [(r.x, r.y), (r.x + r.w, r.y), (r.x + r.w, r.y + r.h), (r.x, r.y + r.h)]
        return Self.homography(from: src, to: quad(width: w, height: h))
    }

    static func homography(from src: [(Double, Double)], to dst: [(x: Double, y: Double)]) -> [Double]? {
        guard src.count == 4, dst.count == 4 else { return nil }
        // 8 уравнений, 8 неизвестных (a…h)
        var m = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let (x, y) = src[i], (u, v) = (dst[i].x, dst[i].y)
            m[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            m[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        // Гаусс с выбором главного элемента
        for col in 0..<8 {
            guard let pivot = (col..<8).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot)
            for row in 0..<8 where row != col {
                let k = m[row][col] / m[col][col]
                if k != 0 { for c in col...8 { m[row][c] -= k * m[col][c] } }
            }
        }
        return (0..<8).map { m[$0][8] / m[$0][$0] } + [1]
    }

    static func apply(_ hm: [Double], _ p: (Double, Double)) -> (x: Double, y: Double) {
        let d = hm[6] * p.0 + hm[7] * p.1 + hm[8]
        return ((hm[0] * p.0 + hm[1] * p.1 + hm[2]) / d, (hm[3] * p.0 + hm[4] * p.1 + hm[5]) / d)
    }
}

/// Пресет площадки: подгонка под её экран
struct VenuePreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var fit: ScreenFit
}
