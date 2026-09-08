import AppKit
import Foundation
import Testing
@testable import LiveryCore

/// Catalog artwork is other people's work: some of it is a proper macOS icon, some is a square sticker painted edge to
/// edge. Only the second kind should be touched.
struct IconGridTests {
    /// Draws `shape` on a transparent canvas and returns PNG bytes, standing in for a downloaded icon.
    private func icon(side: Int = 1024, inset: Double, cornerRadius: Double, colour: NSColor = .systemBlue) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let frame = NSRect(x: inset, y: inset, width: Double(side) - 2 * inset, height: Double(side) - 2 * inset)
        colour.setFill()
        NSBezierPath(roundedRect: frame, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// Fraction of the canvas the opaque pixels span, and whether the extreme corners are painted.
    private func measure(_ data: Data) -> (coverage: Double, cornersPainted: Bool) {
        let source = NSImage(data: data)!
        let rep = NSBitmapImageRep(data: source.tiffRepresentation!)!
        let width = rep.pixelsWide, height = rep.pixelsHigh
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.06 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return (0, false) }
        let coverage = max(Double(maxX - minX + 1) / Double(width), Double(maxY - minY + 1) / Double(height))
        let inset = 3
        let corners = [(minX + inset, minY + inset), (maxX - inset, minY + inset),
                       (minX + inset, maxY - inset), (maxX - inset, maxY - inset)]
        let painted = corners.allSatisfy { (rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 0) > 0.78 }
        return (coverage, painted)
    }

    @Test func aProperIconIsLeftAlone() {
        // 82% coverage with rounded, transparent corners is what a well-made macOS icon looks like.
        let proper = icon(inset: 92, cornerRadius: 185)
        #expect(IconGrid.fitted(proper) == nil)
    }

    @Test func aFullBleedSquareIsScaledAndRounded() throws {
        let sticker = icon(inset: 0, cornerRadius: 0)
        let before = measure(sticker)
        #expect(before.coverage > 0.99)
        #expect(before.cornersPainted)

        let fitted = try #require(IconGrid.fitted(sticker))
        let after = measure(fitted)
        // Down to the macOS tile, and the hard corners are gone.
        #expect(after.coverage > 0.74 && after.coverage < 0.86)
        #expect(!after.cornersPainted)
    }

    @Test func aFullBleedRoundedTileIsScaledButKeepsItsShape() throws {
        let bleeding = icon(inset: 0, cornerRadius: 230)
        let fitted = try #require(IconGrid.fitted(bleeding))
        let after = measure(fitted)
        #expect(after.coverage > 0.74 && after.coverage < 0.86)
        #expect(!after.cornersPainted)
    }

    @Test func anAlreadyCentredSquareStickerIsStillRounded() throws {
        // Scaling alone used to leave this case a small hard-cornered square.
        let centredSquare = icon(inset: 100, cornerRadius: 0)
        let fitted = try #require(IconGrid.fitted(centredSquare))
        #expect(!measure(fitted).cornersPainted)
    }

    @Test func aTransparentImageIsLeftAlone() {
        let blank = icon(inset: 0, cornerRadius: 0, colour: .clear)
        #expect(IconGrid.fitted(blank) == nil)
    }

    @Test func anOversizedCanvasIsClamped() throws {
        // A catalog entry claiming a huge canvas must not turn into a huge allocation.
        let large = icon(side: 4096, inset: 0, cornerRadius: 0)
        let fitted = try #require(IconGrid.fitted(large))
        let rep = NSBitmapImageRep(data: NSImage(data: fitted)!.tiffRepresentation!)!
        #expect(rep.pixelsWide <= IconGrid.maxCanvasSide)
    }
}
