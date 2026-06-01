import UIKit

// MARK: - Palette cache (RAM + disk, 13 bytes per entry)

/// Caches extracted `AlbumPalette` values so detail views that revisit an
/// already-seen cover skip the pixel-level extraction entirely.
/// Thread-safe: NSCache for RAM, serial DispatchQueue for disk I/O.
final class PaletteCache: @unchecked Sendable {
    static let shared = PaletteCache()

    private let memory = NSCache<NSString, PaletteBox>()
    private let diskDir: URL
    private let ioQueue = DispatchQueue(label: "palette.cache.io", qos: .utility)

    private init() {
        memory.countLimit = 500
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDir = caches.appendingPathComponent("palette_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    // MARK: Read

    func palette(for key: String) -> AlbumPalette? {
        // 1. RAM
        if let box = memory.object(forKey: key as NSString) { return box.palette }
        // 2. Disk — 13-byte binary: R G B  R G B  R G B  isSolid
        let path = diskDir.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: path), data.count == 13 else { return nil }
        let p = decodePalette(data)
        memory.setObject(PaletteBox(p), forKey: key as NSString)
        return p
    }

    // MARK: Write

    func set(_ palette: AlbumPalette, for key: String) {
        memory.setObject(PaletteBox(palette), forKey: key as NSString)
        let data = encodePalette(palette)
        let path = diskDir.appendingPathComponent(key)
        ioQueue.async { try? data.write(to: path, options: .atomic) }
    }

    // MARK: Invalidate

    func invalidate(key: String) {
        memory.removeObject(forKey: key as NSString)
        let path = diskDir.appendingPathComponent(key)
        ioQueue.async { try? FileManager.default.removeItem(at: path) }
    }

    // MARK: Binary encode/decode — 13 bytes: 3×(R,G,B) + 1×isSolid

    private func encodePalette(_ p: AlbumPalette) -> Data {
        var bytes = [UInt8](repeating: 0, count: 13)
        func write(_ color: UIColor, offset: Int) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: nil)
            bytes[offset]     = UInt8(clamping: Int(r * 255))
            bytes[offset + 1] = UInt8(clamping: Int(g * 255))
            bytes[offset + 2] = UInt8(clamping: Int(b * 255))
        }
        write(p.primary, offset: 0)
        write(p.secondary, offset: 3)
        write(p.accent, offset: 6)
        bytes[9]  = 0 // reserved
        bytes[10] = 0 // reserved
        bytes[11] = 0 // reserved
        bytes[12] = p.isSolid ? 1 : 0
        return Data(bytes)
    }

    private func decodePalette(_ data: Data) -> AlbumPalette {
        let b = [UInt8](data)
        func color(_ o: Int) -> UIColor {
            UIColor(red: CGFloat(b[o]) / 255, green: CGFloat(b[o+1]) / 255, blue: CGFloat(b[o+2]) / 255, alpha: 1)
        }
        return AlbumPalette(primary: color(0), secondary: color(3), accent: color(6), isSolid: b[12] == 1)
    }

    /// NSCache requires reference-type values.
    private final class PaletteBox {
        let palette: AlbumPalette
        init(_ palette: AlbumPalette) { self.palette = palette }
    }
}

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

    // MARK: Apple Music-style buttons (iOS 26.4)
    //
    // Apple Music NO usa "el píxel más vibrante" como acento. Usa un color
    // **en la misma familia que el primary** (mismo HUE de la cover),
    // saturación boosteada y luminancia opuesta al fondo donde se renderiza.
    // De ese modo el botón siempre queda coherente con la cover y legible.
    //
    // Play = pill cuyo background contrasta con el fondo del hero
    //        (blanco sobre hero oscuro/motion, negro sobre hero claro)
    //        con texto en harmonic accent.
    // Shuffle = círculo de harmonic accent con icono blanco/negro según
    //           la luminancia del propio harmonic accent.

    /// Luminancia perceptual de un UIColor (Rec. 709).
    private func luminance(of color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: nil)
        return r * 0.299 + g * 0.587 + b * 0.114
    }

    /// Acento armónico — algoritmo en 3 tiers, alineado con el approach
    /// conservador de Apple Music y la Palette API de Android.
    ///
    /// Principios:
    ///  - La "identidad" cromática de un álbum es su color dominante con
    ///    HUE robusto y brightness en RANGO NATURAL [0.20, 0.85]. Brightness
    ///    fuera de este rango indica "casi blanco/negro" — un tinte que el
    ///    averaging del extractor puede haber amplificado artificialmente
    ///    (ej. cover negra con halo rosa de aliasing) y NO debe usarse.
    ///  - Los detalles minoritarios (logo rosa en cover blanca, texto rojo
    ///    en cover negra) NO son la identidad del álbum y se descartan.
    ///  - Cuando el primary no es fiable, se cae a un monocromático sutil
    ///    (gris #333 o #DBDBDB) — exactamente como hace Apple en Abbey Road
    ///    o White Album.
    ///
    ///  Tier 1: primary con saturación ≥ 0.20 y brightness ∈ [0.20, 0.85].
    ///  Tier 2: accent con saturación ≥ 0.55 y brightness ∈ [0.25, 0.85],
    ///          SOLO si el primary no es extremo y no es gris.
    ///  Tier 3: monocromático, gris contrastante con el button bg.
    ///
    /// El parámetro `targetBrightness` permite que Play (texto) use uno
    /// más oscuro/profundo (0.38–0.74) y Shuffle (background) use uno
    /// más medio (0.55) — más vivo, sin parecer vino tinto saturado.
    private func harmonicAccent(buttonBgIsLight: Bool, targetBrightness: CGFloat) -> UIColor {
        let minSaturation: CGFloat = 0.55

        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0

        // Tier 1 — primary saturado con brightness natural.
        primary.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s >= 0.20 && b >= 0.20 && b <= 0.85 {
            return UIColor(hue: h, saturation: max(s, minSaturation), brightness: targetBrightness, alpha: 1)
        }

        // Detectar si el primary es "no informativo": brightness extrema
        // (blanco/negro) o saturación muy baja (gris). En ambos casos NO
        // se debe rescatar con accent — el accent representaría un detalle,
        // no la identidad del álbum.
        let primaryIsExtreme = b < 0.20 || b > 0.85
        let primaryIsGray = s < 0.10

        // Tier 2 — accent muy saturado SOLO si primary aporta algo de color
        // (cuasi-neutro intermedio, ni extremo ni gris puro).
        if !primaryIsExtreme && !primaryIsGray {
            accent.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            if s >= 0.55 && b >= 0.25 && b <= 0.85 {
                return UIColor(hue: h, saturation: max(s, minSaturation), brightness: targetBrightness, alpha: 1)
            }
        }

        // Tier 3 — monocromático. Sin tint. Apple-style para covers neutras.
        return buttonBgIsLight
            ? UIColor(white: 0.20, alpha: 1)
            : UIColor(white: 0.86, alpha: 1)
    }

    /// Background del botón Play. Contrasta con el fondo del hero. Con motion
    /// el hero se trata como oscuro (scrim oscuro debajo del vídeo destaca
    /// siempre el blanco).
    func playButtonBackground(motionPresent: Bool) -> UIColor {
        let heroIsLight = !motionPresent && isPrimaryLight
        return heroIsLight ? .black : .white
    }

    /// Foreground del botón Play. Brightness profunda (0.38 sobre blanco,
    /// 0.74 sobre negro) para garantizar contraste WCAG AA (4.5:1) con el
    /// button bg, sin caer en colores "vino tinto" demasiado oscuros.
    func playButtonForeground(motionPresent: Bool) -> UIColor {
        let bg = playButtonBackground(motionPresent: motionPresent)
        let bgIsLight = luminance(of: bg) > 0.5
        let targetBrightness: CGFloat = bgIsLight ? 0.38 : 0.74
        return harmonicAccent(buttonBgIsLight: bgIsLight, targetBrightness: targetBrightness)
    }

    /// Background del botón Shuffle. Brightness MEDIA (0.55) para que el
    /// shuffle se vea vivo y diferenciado del Play (cuyo bg es blanco/negro
    /// puro), sin parecer un "vino tinto" oscuro saturado. El threshold de
    /// luminancia del fg (0.45) permite que texto NEGRO se use sobre HUEs
    /// medios-claros, lo que da una estética más natural.
    func shuffleButtonBackground(motionPresent: Bool) -> UIColor {
        let heroIsLight = !motionPresent && isPrimaryLight
        return harmonicAccent(buttonBgIsLight: heroIsLight, targetBrightness: 0.55)
    }

    /// Foreground del botón Shuffle. Negro si el bg es medio-claro (lum
    /// > 0.45), blanco si es oscuro. Threshold más permisivo que 0.55
    /// para favorecer texto negro sobre HUEs medios (más Apple-style).
    func shuffleButtonForeground(motionPresent: Bool) -> UIColor {
        let bg = shuffleButtonBackground(motionPresent: motionPresent)
        return luminance(of: bg) > 0.45 ? .black : .white
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
