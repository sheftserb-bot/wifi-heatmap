import Foundation
import SwiftUI

// MARK: - Geometry

struct Vec2: Codable, Hashable {
    var x: Double
    var y: Double

    static let zero = Vec2(x: 0, y: 0)
    static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: Vec2, k: Double) -> Vec2 { Vec2(x: a.x * k, y: a.y * k) }

    var length: Double { (x * x + y * y).squareRoot() }
    func distance(to o: Vec2) -> Double { (self - o).length }
    func rotated(by a: Double) -> Vec2 {
        let c = cos(a), s = sin(a)
        return Vec2(x: x * c - y * s, y: x * s + y * c)
    }
}

enum OpeningKind: String, Codable { case door, window, opening }

struct PlanSegment: Codable, Hashable {
    var a: Vec2
    var b: Vec2
}

struct PlanOpening: Codable, Hashable {
    var a: Vec2
    var b: Vec2
    var kind: OpeningKind
}

/// Floor plan in metres, already rotated into plan coordinates.
struct FloorPlan: Codable {
    var walls: [PlanSegment] = []
    var openings: [PlanOpening] = []
}

// MARK: - Survey data

struct Sample: Codable, Identifiable, Hashable {
    var id = UUID()
    var pos: Vec2
    var date = Date()
    var down: Double?
    var up: Double?
    var ping: Double?
    var jitter: Double?
    var failed = false
    var server = ""
    var error: String?
}

struct Survey: Codable, Identifiable {
    var id = UUID()
    var name: String
    var created = Date()
    var plan: FloorPlan?
    /// World (x, z) -> plan: rotate by `rotation`, then add `offset`.
    var rotation: Double = 0
    var offset: Vec2 = .zero
    var start: Vec2?
    var points: [Sample] = []
    var trail: [Vec2] = []
    var hasWorldMap = false
    /// Floor plan image (non-LiDAR phones). Image top-left sits at plan (0, 0).
    var planImageFile: String?
    var imagePixels: Vec2?
    var metersPerPixel: Double?
    /// True until the 2-point alignment has linked the camera position to the image.
    var needsAlignment: Bool?

    var imageRect: CGRect? {
        guard planImageFile != nil, let px = imagePixels, let mpp = metersPerPixel else { return nil }
        return CGRect(x: 0, y: 0, width: px.x * mpp, height: px.y * mpp)
    }

    func toPlan(worldX x: Double, z: Double) -> Vec2 {
        Vec2(x: x, y: z).rotated(by: rotation) + offset
    }

    /// Area to show: plan, points, trail and an optional extra point, padded.
    func bounds(including extra: Vec2? = nil) -> CGRect {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        func add(_ p: Vec2) {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        plan?.walls.forEach { add($0.a); add($0.b) }
        points.forEach { add($0.pos) }
        trail.forEach { add($0) }
        if let s = start { add(s) }
        if let e = extra { add(e) }
        if let r = imageRect {
            add(Vec2(x: Double(r.minX), y: Double(r.minY))); add(Vec2(x: Double(r.maxX), y: Double(r.maxY)))
        }
        guard minX.isFinite else { return CGRect(x: -3, y: -3, width: 6, height: 6) }
        let pad = imageRect == nil ? 1.0 : 0.3
        let w = max(4, maxX - minX + 2 * pad), h = max(4, maxY - minY + 2 * pad)
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}

// MARK: - Metrics and colours

enum Metric: String, CaseIterable, Identifiable {
    case down, up, ping
    var id: String { rawValue }

    var title: String {
        switch self {
        case .down: return "Download"
        case .up: return "Upload"
        case .ping: return "Ping"
        }
    }
    var short: String {
        switch self {
        case .down: return "↓ Down"
        case .up: return "↑ Up"
        case .ping: return "Ping"
        }
    }
    var unit: String { self == .ping ? "ms" : "Mbps" }

    func value(_ m: Sample) -> Double? {
        if m.failed { return nil }
        switch self {
        case .down: return m.down
        case .up: return m.up
        case .ping: return m.ping
        }
    }
}

func fmt(_ v: Double?) -> String {
    guard let v, v.isFinite else { return "–" }
    return v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v)
}

enum K {
    static let server = "serverMode"
    static let localURL = "localURL"
    static let secs = "testSeconds"
    static let spacing = "autoSpacing"
    static let downBad = "thDownBad", downGood = "thDownGood"
    static let upBad = "thUpBad", upGood = "thUpGood"
    static let pingBad = "thPingBad", pingGood = "thPingGood"
    static let showHeat = "showHeat", showLabels = "showLabels"
}

enum TestSettings {
    private static var d: UserDefaults { .standard }
    static var serverMode: String { d.string(forKey: K.server) ?? "auto" }
    static var localURL: String { d.string(forKey: K.localURL) ?? "" }
    static var seconds: Double { let v = d.double(forKey: K.secs); return v > 0 ? v : 3 }
    static var spacing: Double { let v = d.double(forKey: K.spacing); return v > 0 ? v : 3 }
}

struct Thresholds: Equatable {
    var downBad = 10.0, downGood = 300.0
    var upBad = 5.0, upGood = 100.0
    var pingBad = 60.0, pingGood = 5.0

    static var current: Thresholds {
        let d = UserDefaults.standard
        func v(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
        return Thresholds(downBad: v(K.downBad, 10), downGood: v(K.downGood, 300),
                          upBad: v(K.upBad, 5), upGood: v(K.upGood, 100),
                          pingBad: v(K.pingBad, 60), pingGood: v(K.pingGood, 5))
    }

    func range(_ m: Metric) -> (bad: Double, good: Double) {
        switch m {
        case .down: return (downBad, downGood)
        case .up: return (upBad, upGood)
        case .ping: return (pingBad, pingGood)
        }
    }

    /// 0 = bad, 1 = good
    func norm(_ m: Metric, _ v: Double?) -> Double {
        guard let v else { return 0 }
        let r = range(m)
        if m == .ping {
            return min(1, max(0, (r.bad - v) / max(r.bad - r.good, 0.001)))
        }
        let lb = log(max(r.bad, 0.01)), lg = log(max(r.good, 0.02))
        return min(1, max(0, (log(max(v, 0.01)) - lb) / max(lg - lb, 0.001)))
    }
}

enum Ramp {
    static let stops: [(Double, (Double, Double, Double))] = [
        (0, (215, 25, 28)), (0.25, (241, 124, 74)), (0.5, (253, 195, 95)),
        (0.75, (196, 228, 125)), (1, (26, 150, 65))
    ]
    static func rgb(_ t: Double) -> (Double, Double, Double) {
        let t = min(1, max(0, t))
        for i in 1..<stops.count where t <= stops[i].0 {
            let (t0, a) = stops[i - 1], (t1, b) = stops[i]
            let f = (t - t0) / (t1 - t0)
            return (a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
        }
        return stops[stops.count - 1].1
    }
    static func color(_ t: Double) -> Color {
        let c = rgb(t)
        return Color(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255)
    }
    static var gradient: Gradient {
        Gradient(stops: stops.map { Gradient.Stop(color: color($0.0), location: $0.0) })
    }
}
