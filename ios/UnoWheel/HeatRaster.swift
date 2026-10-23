import Accelerate
import CoreGraphics
import MapKit

/// Rasterises rides into one map tile the way Strava does: each ride is
/// stroked once as a thin line onto a shared buffer, the buffer is turned
/// into ride counts, and a blur of those counts makes the glow. Overlaps add
/// up, so busy paths glow on their own. Stroking once and blurring is several
/// times cheaper than stacking wide strokes, which matters because MapKit
/// draws every tile again on each zoom step.
enum HeatRaster {
    struct Track: Sendable {
        let points: [MKMapPoint]
        let rect: MKMapRect

        init?(points: [MKMapPoint]) {
            guard points.count > 1 else { return nil }
            self.points = points
            rect = MKMapRect(enclosing: points)
        }
    }

    /// Core line width and glow radius (blur sigma) in screen points at
    /// street zoom.
    static let coreWidth: CGFloat = 2.2
    static let glowSigma: CGFloat = 3
    /// Share of a pixel's heat from the sharp core versus the glow.
    static let coreShare: Float = 0.45
    /// Heat below this is left transparent.
    private static let faintest: Float = 0.004

    struct Stop {
        let t, red, green, blue, alpha: Double
    }

    /// Hot ramp from faint dark red to near white, with alpha so the edges
    /// of the glow fade into the map.
    static let ramp = [
        Stop(t: 0.00, red: 0.55, green: 0.00, blue: 0.05, alpha: 0.00),
        Stop(t: 0.08, red: 0.75, green: 0.05, blue: 0.05, alpha: 0.65),
        Stop(t: 0.35, red: 0.98, green: 0.30, blue: 0.05, alpha: 0.90),
        Stop(t: 0.65, red: 1.00, green: 0.75, blue: 0.15, alpha: 1.00),
        Stop(t: 1.00, red: 1.00, green: 1.00, blue: 0.85, alpha: 1.00),
    ]

    /// Widths are fixed in metres on the ground (sizes above are for zoom
    /// 16, street level), so they double with each zoom level. MapKit draws
    /// tiles at whole zoom levels and stretches them in between; with widths
    /// in metres a stretched tile matches the next level's tile exactly, so
    /// zooming has no visible steps. Outside about zoom 13.7 to 17.3 the
    /// width is clamped so lines stay visible zoomed out and don't swell
    /// zoomed in.
    static func widthScale(zoomScale: Double) -> CGFloat {
        let zoom = 20 + log2(zoomScale)
        return CGFloat(min(2.5, max(0.2, pow(2, zoom - 16))))
    }

    /// Ride counts to colours, built once per overlay. Colours are indexed
    /// by `sqrt(heat / brightest)`, so faint glow keeps resolution. Heat runs
    /// through a log curve so one ride is dark red and the most ridden paths
    /// go white.
    struct Palette: Sendable {
        private static let steps = 4096
        private let colours: [UInt32]
        private let top: Float

        /// `brightest` is the ride count that maps to the top of the ramp.
        init(brightest: Int) {
            let top = Double(max(brightest, 2))
            self.top = Float(top)
            colours = (0..<Self.steps).map { index in
                let heat = pow(Double(index) / Double(Self.steps - 1), 2) * top
                return HeatRaster.colour(at: log1p(heat) / log1p(top))
            }
        }

        func colour(heat: Float) -> UInt32 {
            colours[min(Self.steps - 1, Int((heat / top).squareRoot() * Float(Self.steps - 1)))]
        }
    }

    /// Premultiplied RGBA bytes, packed little-endian.
    private static func colour(at t: Double) -> UInt32 {
        let upper = ramp.firstIndex { $0.t >= t } ?? ramp.count - 1
        let lower = ramp[max(0, upper - 1)], higher = ramp[upper]
        let span = higher.t - lower.t
        let f = span > 0 ? (t - lower.t) / span : 0
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * f }
        let alpha = mix(lower.alpha, higher.alpha)
        func byte(_ value: Double) -> UInt32 { UInt32(value * 255) }
        return byte(mix(lower.red, higher.red) * alpha)
            | byte(mix(lower.green, higher.green) * alpha) << 8
            | byte(mix(lower.blue, higher.blue) * alpha) << 16
            | byte(alpha) << 24
    }

    /// Core Graphics has no additive blend for grey bitmaps, so each ride is
    /// drawn with normal blending at alpha `1 - e^(-k)`. Stacked, a pixel
    /// reaches `1 - e^(-rides * k)`, which inverts exactly back to the ride
    /// count. With k = 0.02 a 16-bit buffer resolves a few hundred rides;
    /// the 8-bit fallback uses k = 0.12 and resolves about 45.
    private struct Depth: Sendable {
        let bits: Int
        let k: Double
        /// Ride count for every possible buffer value.
        let counts: [Float]

        init(bits: Int, k: Double) {
            self.bits = bits
            self.k = k
            let full = Double((1 << bits) - 1)
            counts = (0..<(1 << bits)).map { Float(-log(max(1e-9, 1 - Double($0) / full)) / k) }
        }
    }

    private static let deep = Depth(bits: 16, k: 0.02)
    private static let shallow = Depth(bits: 8, k: 0.12)

    /// Pixel geometry for one tile. The tile is drawn with a margin so the
    /// blur near its edges sees the lines just outside it; otherwise tiles
    /// would show seams.
    private struct Tile {
        let width, height: Int
        let pad: Int
        let paddedWidth, paddedHeight: Int
        let paddedRect: MKMapRect
        let pixelsPerMapPoint: Double
        let corePixels: CGFloat
        let sigma: Float
        let radius: Int

        init(mapRect: MKMapRect, width: Int, height: Int, zoomScale: Double) {
            self.width = width
            self.height = height
            pixelsPerMapPoint = Double(width) / mapRect.width
            let pixelsPerScreenPoint = CGFloat(pixelsPerMapPoint / zoomScale)
            let scale = HeatRaster.widthScale(zoomScale: zoomScale)
            corePixels = max(1, HeatRaster.coreWidth * scale * pixelsPerScreenPoint)
            sigma = max(0.8, Float(HeatRaster.glowSigma * scale * pixelsPerScreenPoint))
            radius = Int((sigma * 3).rounded(.up))
            pad = radius + Int(corePixels.rounded(.up))
            paddedWidth = width + 2 * pad
            paddedHeight = height + 2 * pad
            paddedRect = mapRect.insetBy(dx: -Double(pad) / pixelsPerMapPoint, dy: -Double(pad) / pixelsPerMapPoint)
        }
    }

    /// Renders `mapRect` into an upright image of `width` x `height` pixels.
    static func image(tracks: [Track], palette: Palette, mapRect: MKMapRect, width: Int, height: Int,
                      zoomScale: Double) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let tile = Tile(mapRect: mapRect, width: width, height: height, zoomScale: zoomScale)
        let paths = tracks.filter { $0.rect.intersects(tile.paddedRect) }.compactMap { clippedPath($0, to: tile) }
        guard !paths.isEmpty, let core = density(of: paths, in: tile), let glow = glow(of: core, in: tile) else { return nil }
        return colourise(core: core, glow: glow, in: tile, palette: palette)
    }

    /// Only segments that touch the tile go into the path, so a tile costs
    /// about what is drawn in it, not the length of every ride.
    private static func clippedPath(_ track: Track, to tile: Tile) -> CGPath? {
        let minStep = 1 / tile.pixelsPerMapPoint
        let path = CGMutablePath()
        var last: MKMapPoint?
        for (a, b) in zip(track.points, track.points.dropFirst()) {
            let segment = MKMapRect(enclosing: [a, b])
            guard segment.intersects(tile.paddedRect) else {
                last = nil
                continue
            }
            if last == nil {
                path.move(to: CGPoint(x: a.x, y: a.y))
                last = a
            }
            if let previous = last, hypot(b.x - previous.x, b.y - previous.y) < minStep { continue }
            path.addLine(to: CGPoint(x: b.x, y: b.y))
            last = b
        }
        return path.isEmpty ? nil : path
    }

    /// Strokes every path once and returns the ride count at each padded pixel.
    private static func density(of paths: [CGPath], in tile: Tile) -> [Float]? {
        guard let (context, depth) = bitmap(width: tile.paddedWidth, height: tile.paddedHeight) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: tile.paddedWidth, height: tile.paddedHeight))
        // Map points to pixels with y down, so memory row 0 is the top.
        context.translateBy(x: 0, y: CGFloat(tile.paddedHeight))
        context.scaleBy(x: tile.pixelsPerMapPoint, y: -tile.pixelsPerMapPoint)
        context.translateBy(x: -tile.paddedRect.minX, y: -tile.paddedRect.minY)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(gray: 1, alpha: 1 - exp(-depth.k))
        context.setLineWidth(tile.corePixels / tile.pixelsPerMapPoint)
        for path in paths {
            context.addPath(path)
            context.strokePath()
        }
        return depth.bits == 16 ? counts(in: context, as: UInt16.self, depth: depth)
            : counts(in: context, as: UInt8.self, depth: depth)
    }

    private static func bitmap(width: Int, height: Int) -> (CGContext, Depth)? {
        let grey = CGColorSpaceCreateDeviceGray()
        if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: grey,
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) {
            return (context, deep)
        }
        if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: grey,
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) {
            return (context, shallow)
        }
        return nil
    }

    private static func counts<Raw: FixedWidthInteger>(in context: CGContext, as _: Raw.Type, depth: Depth) -> [Float]? {
        guard let data = context.data else { return nil }
        let raw = data.assumingMemoryBound(to: Raw.self)
        let width = context.width, height = context.height
        let rowLength = context.bytesPerRow / MemoryLayout<Raw>.stride
        var counts = [Float](repeating: 0, count: width * height)
        depth.counts.withUnsafeBufferPointer { table in
            for y in 0..<height {
                for x in 0..<width { counts[y * width + x] = table[Int(raw[y * rowLength + x])] }
            }
        }
        return counts
    }

    /// Gaussian glow, scaled so one ride's glow peaks at its share of the
    /// heat on the line, the same way its core does.
    private static func glow(of core: [Float], in tile: Tile) -> [Float]? {
        let sigma = tile.sigma, radius = tile.radius
        let gaussian = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = gaussian.reduce(0, +)
        let kernel = gaussian.map { $0 / total }
        let half = Int(tile.corePixels / 2)
        let linePeak = kernel[(radius - half)...(radius + half)].reduce(0, +)
        // The two passes multiply, so the gain goes on one of them.
        let gain = (1 - coreShare) / max(linePeak, 1e-3)
        let kernelX = kernel.map { $0 * gain }

        var core = core
        var glow = [Float](repeating: 0, count: core.count)
        let rowBytes = tile.paddedWidth * MemoryLayout<Float>.stride
        let result: vImage_Error = core.withUnsafeMutableBytes { coreBytes in
            glow.withUnsafeMutableBytes { glowBytes in
                var source = vImage_Buffer(data: coreBytes.baseAddress, height: vImagePixelCount(tile.paddedHeight),
                                           width: vImagePixelCount(tile.paddedWidth), rowBytes: rowBytes)
                var destination = vImage_Buffer(data: glowBytes.baseAddress, height: vImagePixelCount(tile.paddedHeight),
                                                width: vImagePixelCount(tile.paddedWidth), rowBytes: rowBytes)
                return vImageSepConvolve_PlanarF(&source, &destination, nil, 0, 0,
                                                 kernelX, UInt32(kernelX.count), kernel, UInt32(kernel.count),
                                                 0, 0, vImage_Flags(kvImageBackgroundColorFill))
            }
        }
        return result == kvImageNoError ? glow : nil
    }

    /// Crops the padding away and colours each pixel by its heat.
    private static func colourise(core: [Float], glow: [Float], in tile: Tile, palette: Palette) -> CGImage? {
        var pixels = [UInt32](repeating: 0, count: tile.width * tile.height)
        for y in 0..<tile.height {
            let row = (y + tile.pad) * tile.paddedWidth + tile.pad
            for x in 0..<tile.width {
                let heat = core[row + x] * coreShare + glow[row + x]
                if heat > faintest { pixels[y * tile.width + x] = palette.colour(heat: heat) }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes: pixels, count: pixels.count * 4) as CFData) else { return nil }
        return CGImage(width: tile.width, height: tile.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: tile.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

extension MKMapRect {
    /// The smallest rect holding every point.
    init(enclosing points: some Sequence<MKMapPoint>) {
        self = points.reduce(MKMapRect.null) { $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 0, height: 0))) }
    }
}
