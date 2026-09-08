import AppKit
import Foundation

/// macOS app icons sit on a grid: a rounded tile covering 824 of the 1024 pt canvas, with the margin the Dock and
/// Finder rely on for even spacing. Community catalogs are full of artwork that ignores both halves of that — square
/// stickers with hard corners, or tiles that bleed to the canvas edge — which then render larger and squarer than
/// every neighbouring icon. This puts such artwork back on the grid: scaled to the tile and clipped to the rounded
/// shape. Icons that already follow the grid are left exactly as they are.
public enum IconGrid {
    /// 824 / 1024: the tile's share of the canvas in Apple's icon template.
    public static let tileRatio = 824.0 / 1024.0
    /// 185.4 / 824: the tile's corner radius in the same template.
    public static let cornerRatio = 185.4 / 824.0
    /// Artwork covering more than this much of the canvas has no margin worth keeping.
    public static let fullBleedThreshold = 0.90
    /// Above this alpha a corner counts as painted, which means the artwork is a square sticker rather than a shaped icon.
    private static let opaqueCutoff: UInt8 = 200

    /// Returns PNG data placed on the icon grid, or nil when the artwork already follows it (or cannot be read).
    public static func fitted(_ data: Data) -> Data? {
        guard let image = NSImage(data: data), let canvas = rasterize(image) else { return nil }
        let width = canvas.pixelsWide, height = canvas.pixelsHigh
        guard let box = opaqueBounds(of: canvas) else { return nil }

        let coverage = max(Double(box.width) / Double(width), Double(box.height) / Double(height))
        let isSquareSticker = cornersArePainted(of: canvas, in: box)
        // Either fault is enough: a tile that bleeds off the canvas, or hard corners where a rounded tile belongs.
        guard coverage > fullBleedThreshold || isSquareSticker else { return nil }

        // Never enlarge artwork: only bring oversized tiles down onto the grid.
        let tileSide = tileRatio * Double(max(width, height))
        let scale = min(1.0, tileSide / Double(max(box.width, box.height)))
        let drawnWidth = Double(box.width) * scale, drawnHeight = Double(box.height) * scale
        let frame = NSRect(x: (Double(width) - drawnWidth) / 2, y: (Double(height) - drawnHeight) / 2,
                           width: drawnWidth, height: drawnHeight)
        let source = NSRect(x: Double(box.minX), y: Double(height - 1 - box.maxY),
                            width: Double(box.width), height: Double(box.height))

        guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        output.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
        NSGraphicsContext.current?.imageInterpolation = .high
        if isSquareSticker {
            let radius = cornerRatio * min(drawnWidth, drawnHeight)
            NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).addClip()
        }
        canvas.draw(in: frame, from: source, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return output.representation(using: .png, properties: [:])
    }

    /// The largest canvas worth rasterising. Icons top out at 1024; a catalog image claiming far more would only be
    /// asking Livery to allocate it.
    public static let maxCanvasSide = 2048

    /// Draws the image into a known RGBA bitmap so the pixel layout is predictable whatever the source format was.
    private static func rasterize(_ image: NSImage) -> NSBitmapImageRep? {
        let longest = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        var side = longest > 0 ? longest : Int(max(image.size.width, image.size.height))
        side = min(side, maxCanvasSide)
        guard side > 0 else { return nil }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private struct Bounds {
        var minX: Int, minY: Int, maxX: Int, maxY: Int
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
    }

    /// Samples the corners of the artwork itself, not of the canvas, so an already-centred square tile is still caught.
    private static func cornersArePainted(of rep: NSBitmapImageRep, in box: Bounds) -> Bool {
        let inset = max(2, min(box.width, box.height) / 100)
        let points = [(box.minX + inset, box.minY + inset), (box.maxX - inset, box.minY + inset),
                      (box.minX + inset, box.maxY - inset), (box.maxX - inset, box.maxY - inset)]
        return points.allSatisfy { alpha(of: rep, x: $0.0, y: $0.1) > opaqueCutoff }
    }

    private static func alpha(of rep: NSBitmapImageRep, x: Int, y: Int) -> UInt8 {
        guard let base = rep.bitmapData, rep.samplesPerPixel == 4,
              x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return 0 }
        return (base + y * rep.bytesPerRow + x * (rep.bitsPerPixel / 8) + 3).pointee
    }

    /// Bounding box of pixels that are more than faintly opaque, read straight from the buffer rather than pixel by pixel.
    private static func opaqueBounds(of rep: NSBitmapImageRep) -> Bounds? {
        guard let base = rep.bitmapData, rep.samplesPerPixel == 4 else { return nil }
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let rowBytes = rep.bytesPerRow, pixelBytes = rep.bitsPerPixel / 8
        let cutoff: UInt8 = 16
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = base + y * rowBytes
            for x in 0..<width where (row + x * pixelBytes + 3).pointee > cutoff {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        return Bounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }
}
