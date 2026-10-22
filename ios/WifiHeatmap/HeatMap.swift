import CoreGraphics
import Foundation

struct HeatLayer {
    let image: CGImage
    /// Area the image covers, in plan metres.
    let rect: CGRect
}

enum HeatMap {
    /// Inverse-distance-weighted interpolation of normalised values (0 bad … 1 good).
    /// Colour fades out between 2.5 m and 5 m from the nearest measurement.
    static func make(points: [(Vec2, Double)], bounds: CGRect) -> HeatLayer? {
        guard !points.isEmpty, bounds.width > 0, bounds.height > 0 else { return nil }
        let cell = max(0.08, Double(max(bounds.width, bounds.height)) / 320)
        let cols = max(2, Int((Double(bounds.width) / cell).rounded(.up)))
        let rows = max(2, Int((Double(bounds.height) / cell).rounded(.up)))
        let fullRadius = 2.5
        var px = [UInt8](repeating: 0, count: cols * rows * 4)

        for y in 0..<rows {
            let cy = Double(bounds.minY) + (Double(y) + 0.5) * cell
            for x in 0..<cols {
                let cx = Double(bounds.minX) + (Double(x) + 0.5) * cell
                var ws = 0.0, vs = 0.0, dmin = Double.infinity
                var exact: Double?
                for (p, t) in points {
                    let dx = cx - p.x, dy = cy - p.y
                    let d2 = dx * dx + dy * dy
                    if d2 < 1e-4 { exact = t; dmin = 0; break }
                    let w = 1 / d2
                    ws += w; vs += w * t
                    if d2 < dmin { dmin = d2 }
                }
                let t = exact ?? (vs / ws)
                let d = dmin.squareRoot()
                let a: Double = d <= fullRadius ? 1 : (d >= 2 * fullRadius ? 0 : 1 - (d - fullRadius) / fullRadius)
                let c = Ramp.rgb(t)
                let i = (y * cols + x) * 4
                px[i] = UInt8(c.0 * a)          // premultiplied alpha
                px[i + 1] = UInt8(c.1 * a)
                px[i + 2] = UInt8(c.2 * a)
                px[i + 3] = UInt8(a * 255)
            }
        }

        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let image = CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: cols * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent)
        else { return nil }
        let rect = CGRect(x: bounds.minX, y: bounds.minY,
                          width: CGFloat(Double(cols) * cell), height: CGFloat(Double(rows) * cell))
        return HeatLayer(image: image, rect: rect)
    }
}
