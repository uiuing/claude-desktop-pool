import CoreGraphics
import Foundation

/// Claude Pool's logo: a white cat with a navy collar and a gold ∞ tag on a terracotta tile.
/// A cat has nine lives; Pool hands a conversation to the next account when one runs out.
/// Drawn on Apple's 1024 icon grid (tile 100...924). `scripts/make-icon.swift` compiles this file
/// to write the app icon, and PoolMark draws the same art in the app.
enum PoolIconArt {
    static let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)

    /// The full 1024 canvas with the tile's drop shadow, as the app icon.
    static func icon(pixels: Int) -> CGImage? {
        image(pixels: pixels) { g in
            g.saveGState()
            g.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: col(0, 0.30))
            g.addPath(tile); g.setFillColor(col(0xB9532F)); g.fillPath()
            g.restoreGState()
            draw(g)
        }
    }

    /// Only the tile, filling the image edge to edge, for small marks inside the app.
    static func mark(pixels: Int) -> CGImage? {
        image(pixels: pixels) { g in
            let scale = 1024 / tileRect.width
            g.translateBy(x: 512, y: 512); g.scaleBy(x: scale, y: scale); g.translateBy(x: -512, y: -512)
            draw(g)
        }
    }

    private static func image(pixels: Int, _ body: (CGContext) -> Void) -> CGImage? {
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let g = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        g.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        body(g)
        return g.makeImage()
    }

    private static let fur: UInt32 = 0xFFF8F3, ink: UInt32 = 0x3A1E14, blush: UInt32 = 0xF08A6C, innerEar: UInt32 = 0xF6C9B6
    private static let collar: UInt32 = 0x2F3A66, collarEdge: UInt32 = 0x1A2142

    private static func draw(_ g: CGContext) {
        g.saveGState()
        g.addPath(tile); g.clip()
        g.drawLinearGradient(grad([col(0xE8906A), col(0xB9532F)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        head(g, 512, 548, 212)
        collarAndTag(g, 512, 548)
        g.restoreGState()
    }

    private static func col(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }

    private static func grad(_ c: [CGColor]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: c as CFArray, locations: nil)!
    }

    private static func stroked(_ p: CGPath, _ w: CGFloat) -> CGPath {
        p.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    private static func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGPath {
        let p = CGMutablePath(); p.addLines(between: [a, b, c]); p.closeSubpath(); return p
    }

    /// Superellipse approximating the continuous-corner macOS icon shape.
    private static let tile: CGPath = {
        let r = tileRect, p = CGMutablePath(), n: CGFloat = 5
        for i in 0...1440 {
            let t = CGFloat(i) / 1440 * 2 * .pi, c = cos(t), s = sin(t)
            let pt = CGPoint(x: r.midX + r.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                             y: r.midY + r.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath(); return p
    }()

    private static func head(_ g: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: col(0x5A1E08, 0.28))
        g.beginTransparencyLayer(auxiliaryInfo: nil)
        g.setFillColor(col(fur))
        g.fillEllipse(in: CGRect(x: cx - r, y: cy - r * 0.84, width: 2 * r, height: 1.68 * r))
        for s in [-1.0, 1.0] as [CGFloat] {
            let ear = triangle(CGPoint(x: cx + s * r * 0.95, y: cy + r * 0.10), CGPoint(x: cx + s * r * 0.82, y: cy + r * 1.05),
                               CGPoint(x: cx + s * r * 0.18, y: cy + r * 0.62))
            g.addPath(ear); g.fillPath()
            g.addPath(stroked(ear, r * 0.22)); g.fillPath()
        }
        g.endTransparencyLayer()
        g.restoreGState()

        for s in [-1.0, 1.0] as [CGFloat] {
            let inner = triangle(CGPoint(x: cx + s * r * 0.80, y: cy + r * 0.42), CGPoint(x: cx + s * r * 0.76, y: cy + r * 0.88),
                                 CGPoint(x: cx + s * r * 0.42, y: cy + r * 0.64))
            g.setFillColor(col(innerEar))
            g.addPath(inner); g.fillPath()
            g.addPath(stroked(inner, r * 0.08)); g.fillPath()
            g.setFillColor(col(ink))
            g.fillEllipse(in: CGRect(x: cx + s * r * 0.40 - r * 0.10, y: cy + r * 0.02, width: r * 0.20, height: r * 0.28))
            g.setFillColor(col(0xFFFFFF))
            g.fillEllipse(in: CGRect(x: cx + s * r * 0.40 - r * 0.01, y: cy + r * 0.17, width: r * 0.08, height: r * 0.08))
            g.setFillColor(col(blush, 0.55))
            g.fillEllipse(in: CGRect(x: cx + s * r * 0.62 - r * 0.13, y: cy - r * 0.26, width: r * 0.26, height: r * 0.14))
        }
        let nose = triangle(CGPoint(x: cx - r * 0.08, y: cy - r * 0.08), CGPoint(x: cx + r * 0.08, y: cy - r * 0.08),
                            CGPoint(x: cx, y: cy - r * 0.18))
        g.setFillColor(col(blush))
        g.addPath(nose); g.fillPath()
        g.addPath(stroked(nose, r * 0.05)); g.fillPath()
        g.setStrokeColor(col(ink)); g.setLineWidth(r * 0.045); g.setLineCap(.round)
        g.move(to: CGPoint(x: cx, y: cy - r * 0.20))
        g.addArc(center: CGPoint(x: cx - r * 0.09, y: cy - r * 0.20), radius: r * 0.09, startAngle: 0, endAngle: .pi, clockwise: true)
        g.move(to: CGPoint(x: cx + r * 0.18, y: cy - r * 0.20))
        g.addArc(center: CGPoint(x: cx + r * 0.09, y: cy - r * 0.20), radius: r * 0.09, startAngle: 0, endAngle: .pi, clockwise: true)
        g.strokePath()
    }

    private static func collarAndTag(_ g: CGContext, _ cx: CGFloat, _ cy: CGFloat) {
        let band = CGMutablePath()
        band.move(to: CGPoint(x: cx - 142, y: cy - 145))
        band.addQuadCurve(to: CGPoint(x: cx + 142, y: cy - 145), control: CGPoint(x: cx, y: cy - 238))
        g.saveGState(); g.addPath(stroked(band, 36)); g.clip()
        g.drawLinearGradient(grad([col(collarEdge), col(collar), col(collarEdge)]),
                             start: CGPoint(x: cx - 160, y: 0), end: CGPoint(x: cx + 160, y: 0), options: [])
        g.restoreGState()
        let shine = CGMutablePath()
        shine.move(to: CGPoint(x: cx - 100, y: cy - 150))
        shine.addQuadCurve(to: CGPoint(x: cx + 100, y: cy - 150), control: CGPoint(x: cx, y: cy - 214))
        g.addPath(shine); g.setStrokeColor(col(0xFFFFFF, 0.22)); g.setLineWidth(6); g.setLineCap(.round); g.strokePath()

        g.setStrokeColor(col(0xD9A341)); g.setLineWidth(10)
        g.strokeEllipse(in: CGRect(x: cx - 17, y: cy - 244, width: 34, height: 34))

        let tc = CGPoint(x: cx, y: cy - 300), tr: CGFloat = 76
        let disc = CGRect(x: tc.x - tr, y: tc.y - tr, width: 2 * tr, height: 2 * tr)
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: col(0x5A1E08, 0.38))
        g.setFillColor(col(0xE2A944)); g.fillEllipse(in: disc)
        g.restoreGState()
        g.saveGState(); g.addEllipse(in: disc); g.clip()
        g.drawLinearGradient(grad([col(0xFFE39A), col(0xF0BE55), col(0xC98A2A)]),
                             start: CGPoint(x: disc.minX, y: disc.maxY), end: CGPoint(x: disc.maxX, y: disc.minY), options: [])
        g.restoreGState()
        g.setStrokeColor(col(0xB97A22, 0.9)); g.setLineWidth(5); g.strokeEllipse(in: disc.insetBy(dx: 9, dy: 9))

        func lemniscate(_ dy: CGFloat) -> CGPath {
            let p = CGMutablePath()
            for i in 0...240 {
                let a = CGFloat(i) / 240 * 2 * .pi, d = 1 + sin(a) * sin(a)
                let pt = CGPoint(x: tc.x + 46 * cos(a) / d, y: tc.y + dy + 46 * sin(a) * cos(a) / d)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.closeSubpath(); return p
        }
        g.setLineJoin(.round); g.setLineWidth(13)
        g.addPath(lemniscate(-3)); g.setStrokeColor(col(0xFFF1C8, 0.8)); g.strokePath()
        g.addPath(lemniscate(0)); g.setStrokeColor(col(0x8C5512)); g.strokePath()
        g.saveGState(); g.addEllipse(in: disc); g.clip()
        g.setFillColor(col(0xFFFFFF, 0.35)); g.fillEllipse(in: CGRect(x: tc.x - 52, y: tc.y + 22, width: 46, height: 26))
        g.restoreGState()
    }
}
