import UIKit

// MARK: - Album palette

struct AlbumPalette {
    let primary: UIColor    // dominant background color
    let secondary: UIColor  // secondary gradient color
    let accent: UIColor     // most vibrant color
    let isSolid: Bool       // cover has a flat solid background (Donda, Black Album…)

    static let `default` = AlbumPalette(
        primary:   UIColor(white: 0.10, alpha: 1),
        secondary: UIColor(white: 0.15, alpha: 1),
        accent:    UIColor(white: 0.55, alpha: 1),
        isSolid:   false
    )

    // MARK: Derived colors

    /// True when the primary background is perceptually light.
    var isPrimaryLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        primary.getRed(&r, green: &g, blue: &b, alpha: nil)
        return (r * 0.299 + g * 0.587 + b * 0.114) > 0.5
    }

    /// Page background — blends 30% primary + 70% near-black (dark covers)
    /// or 65% primary + 35% white (light covers). Same formula as the JS frontend.
    var pageBackgroundColor: UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        primary.getRed(&r, green: &g, blue: &b, alpha: nil)
        if isPrimaryLight {
            return UIColor(red: r * 0.65 + 0.35,
                           green: g * 0.65 + 0.35,
                           blue:  b * 0.65 + 0.35, alpha: 1)
        } else {
            let base: CGFloat = 14.0 / 255.0   // #0e0e0e
            return UIColor(red:   r * 0.30 + base * 0.70,
                           green: g * 0.30 + base * 0.70,
                           blue:  b * 0.30 + base * 0.70, alpha: 1)
        }
    }

    /// Sticky header background — 45% of primary.
    var stickyBgColor: UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        primary.getRed(&r, green: &g, blue: &b, alpha: nil)
        return UIColor(red: r * 0.45, green: g * 0.45, blue: b * 0.45, alpha: 1)
    }

    /// Play button fill — accent boosted ×1.1.
    var buttonFillColor: UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        accent.getRed(&r, green: &g, blue: &b, alpha: nil)
        return UIColor(red: min(r * 1.1, 1), green: min(g * 1.1, 1), blue: min(b * 1.1, 1), alpha: 1)
    }

    /// Whether the play button needs black text (high-luminance fill).
    var buttonUsesBlackText: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        buttonFillColor.getRed(&r, green: &g, blue: &b, alpha: nil)
        return (r * 0.299 + g * 0.587 + b * 0.114) > 0.706  // > 180/255
    }
}

// MARK: - Extractor

/// Pixel-level color extraction — mirrors useDominantColors.ts logic.
/// All heavy work runs on a background thread; caller is responsible for dispatch.
enum ColorExtractor {

    // MARK: Public

    static func extract(from image: UIImage) -> AlbumPalette {
        guard let cgImage = image.cgImage else { return .default }

        // Resize to ≤200px for performance (same as canvas approach in JS).
        let maxDim = 200
        let scale  = min(CGFloat(maxDim) / CGFloat(max(cgImage.width, cgImage.height)), 1.0)
        let w = max(1, Int(CGFloat(cgImage.width)  * scale))
        let h = max(1, Int(CGFloat(cgImage.height) * scale))

        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &px, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .default }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Solid-color detection (JS detectSolidColor).
        if let (bg, acc) = detectSolid(px: px, w: w, h: h) {
            return AlbumPalette(primary: bg, secondary: bg, accent: acc, isSolid: true)
        }

        // General palette (JS extractCanvasPalette).
        let (pri, sec, acc) = extractPalette(px: px, w: w, h: h)
        return AlbumPalette(primary: pri, secondary: sec, accent: acc, isSolid: false)
    }

    // MARK: Pixel helpers

    private static func rgb(_ px: [UInt8], _ i: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let o = i * 4
        return (CGFloat(px[o]) / 255, CGFloat(px[o+1]) / 255, CGFloat(px[o+2]) / 255)
    }

    private static func hsv(r: CGFloat, g: CGFloat, b: CGFloat) -> (h: CGFloat, s: CGFloat, v: CGFloat) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h: CGFloat = 0
        if d > 0 {
            switch mx {
            case r: h = (g - b) / d + (g < b ? 6 : 0)
            case g: h = (b - r) / d + 2
            default: h = (r - g) / d + 4
            }
            h /= 6
        }
        return (h, mx > 0 ? d / mx : 0, mx)
    }

    // MARK: Solid detection

    /// Mirrors JS detectSolidColor: samples border ring (12% of shorter side),
    /// quantises into 64-step buckets, declares solid when ≥55% agree.
    /// Returns the **true average** colour of the winning bucket's pixels
    /// (not the quantised centroid) so whites stay white, creams stay cream, etc.
    private static func detectSolid(px: [UInt8], w: Int, h: Int) -> (UIColor, UIColor)? {
        let depth = max(3, Int(CGFloat(min(w, h)) * 0.12))

        struct Bucket: Hashable { let r, g, b: UInt8 }
        var counts: [Bucket: Int] = [:]
        // Accumulate real RGB sums per bucket so we can average later.
        var sums: [Bucket: (r: UInt64, g: UInt64, b: UInt64)] = [:]
        var total = 0

        func add(_ x: Int, _ y: Int) {
            let o = (y * w + x) * 4
            let pr = px[o], pg = px[o+1], pb = px[o+2]
            let bk = Bucket(
                r: UInt8(UInt16(pr) / 64 * 64),
                g: UInt8(UInt16(pg) / 64 * 64),
                b: UInt8(UInt16(pb) / 64 * 64)
            )
            counts[bk, default: 0] += 1
            let prev = sums[bk, default: (0, 0, 0)]
            sums[bk] = (prev.r + UInt64(pr), prev.g + UInt64(pg), prev.b + UInt64(pb))
            total += 1
        }

        for x in 0..<w {
            for d in 0..<depth { add(x, d); add(x, h-1-d) }
        }
        for y in depth..<(h-depth) {
            for d in 0..<depth { add(d, y); add(w-1-d, y) }
        }

        guard total > 0,
              let dominant = counts.max(by: { $0.value < $1.value }),
              CGFloat(dominant.value) / CGFloat(total) >= 0.55
        else { return nil }

        // Use the real average of pixels that fell into the dominant bucket.
        let n = UInt64(dominant.value)
        let s = sums[dominant.key]!
        let bgR = CGFloat(s.r / n) / 255
        let bgG = CGFloat(s.g / n) / 255
        let bgB = CGFloat(s.b / n) / 255
        let bg  = UIColor(red: bgR, green: bgG, blue: bgB, alpha: 1)
        let acc = vibrantAccent(px: px, w: w, h: h, exclude: (bgR, bgG, bgB))
        return (bg, acc)
    }

    // MARK: Vibrant accent

    private static func vibrantAccent(
        px: [UInt8], w: Int, h: Int,
        exclude: (r: CGFloat, g: CGFloat, b: CGFloat)
    ) -> UIColor {
        let total = w * h
        struct Entry { var r, g, b, score: CGFloat; var count: Int }
        var buckets = [Int: Entry]()  // hue × 36

        for i in 0..<total {
            let (r, g, b) = rgb(px, i)
            // Skip pixels close to the background
            if abs(r - exclude.r) + abs(g - exclude.g) + abs(b - exclude.b) < 0.15 { continue }
            let (h, s, v) = hsv(r: r, g: g, b: b)
            if s < 0.25 { continue }

            let bucket = Int(h * 36) % 36
            let score  = s * v
            if var e = buckets[bucket] {
                let t = 1.0 / CGFloat(e.count + 1)
                e.r = e.r * (1-t) + r * t
                e.g = e.g * (1-t) + g * t
                e.b = e.b * (1-t) + b * t
                e.score = max(e.score, score)
                e.count += 1
                buckets[bucket] = e
            } else {
                buckets[bucket] = Entry(r: r, g: g, b: b, score: score, count: 1)
            }
        }

        let threshold = max(1, Int(CGFloat(total) * 0.015))
        let best = buckets.values
            .filter { $0.count >= threshold }
            .max(by: { $0.score < $1.score })
            ?? buckets.values.max(by: { $0.score < $1.score })

        if let best {
            return UIColor(red: best.r, green: best.g, blue: best.b, alpha: 1)
        }
        // Pure neutral fallback
        let lum = exclude.r * 0.299 + exclude.g * 0.587 + exclude.b * 0.114
        return UIColor(white: lum > 0.5 ? 0.2 : 0.67, alpha: 1)
    }

    // MARK: General palette

    /// 13-point strategic sampling — mirrors JS extractCanvasPalette.
    private static func extractPalette(px: [UInt8], w: Int, h: Int)
        -> (UIColor, UIColor, UIColor)
    {
        let pts: [(CGFloat, CGFloat)] = [
            (0,0),(1,0),(0,1),(1,1),
            (0.5,0.5),
            (0.25,0.25),(0.75,0.25),(0.25,0.75),(0.75,0.75),
            (0.5,0.25),(0.5,0.75),(0.25,0.5),(0.75,0.5)
        ]

        struct Sample { var r, g, b, score: CGFloat }
        var samples: [Sample] = pts.map { (fx, fy) in
            let x = min(Int(fx * CGFloat(w - 1)), w - 1)
            let y = min(Int(fy * CGFloat(h - 1)), h - 1)
            let (r, g, b) = rgb(px, y * w + x)
            let (_, s, v) = hsv(r: r, g: g, b: b)
            return Sample(r: r, g: g, b: b, score: s * 0.7 + v * 0.3)
        }
        samples.sort { $0.score > $1.score }

        let n = samples.count
        func color(_ s: Sample) -> UIColor { UIColor(red: s.r, green: s.g, blue: s.b, alpha: 1) }
        return (color(samples[n/3]), color(samples[n*2/3]), color(samples[0]))
    }
}
