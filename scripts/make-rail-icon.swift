// Draws the approved rounded R as vector paths and packages it for the app.
// The approved artwork, design/icon/rail-r-variants/rail-r-02-rounded.png, is the reference;
// this is a clean reconstruction of its geometry, so every size stays smooth and crisp.
// Run from any directory: swift /path/to/rail/scripts/make-rail-icon.swift
import AppKit
import ImageIO

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let reference = root.appendingPathComponent("design/icon/rail-r-variants/rail-r-02-rounded.png")
let previews = root.appendingPathComponent("design/icon/rail-r")
let icns = root.appendingPathComponent("resources/AppIcon.icns")
let markPDF = root.appendingPathComponent("resources/RailMark.pdf")
let files = FileManager.default
try files.createDirectory(at: previews, withIntermediateDirectories: true)

// Sampled from the reference: warm cream on near-black.
let cream = CGColor(srgbRed: 254 / 255, green: 239 / 255, blue: 215 / 255, alpha: 1)   // #FEEFD7
let ink = CGColor(srgbRed: 5 / 255, green: 5 / 255, blue: 5 / 255, alpha: 1)           // #050505

// MARK: Geometry, in the reference image's pixels (y down). Its tile spans 100…1154.

let tileOrigin: CGFloat = 100, tileSide: CGFloat = 1054

// The leg's edges, fitted to the reference; it widens very slightly towards its foot.
func legLeft(_ y: CGFloat) -> CGFloat { 646.5 + 0.933 * (y - 800) }
func legRight(_ y: CGFloat) -> CGFloat { 811 + 0.956 * (y - 800) }

let top: CGFloat = 321.5, bottom: CGFloat = 943.5, stemLeft: CGFloat = 342, stemRight: CGFloat = 460.5
let barBottom: CGFloat = 692
let bowlCenter = CGPoint(x: 729.8, y: 506.0), bowlRadius: CGFloat = 183.6

/// A closed polygon whose corners are rounded with the given radii (0 keeps a corner sharp).
func rounded(_ points: [CGPoint], _ radii: [CGFloat]) -> CGPath {
    let path = CGMutablePath()
    let n = points.count
    let start = CGPoint(x: (points[n - 1].x + points[0].x) / 2, y: (points[n - 1].y + points[0].y) / 2)
    path.move(to: start)
    for i in 0..<n {
        let next = points[(i + 1) % n]
        if radii[i] > 0 { path.addArc(tangent1End: points[i], tangent2End: next, radius: radii[i]) }
        else { path.addLine(to: points[i]) }
    }
    path.closeSubpath()
    return path
}

/// Where the leg's outer edge meets the underside of the bowl, and the tip of the notch between them.
func notchTip() -> CGPoint {
    var lo: CGFloat = 640, hi: CGFloat = 720
    for _ in 0..<60 {
        let y = (lo + hi) / 2, x = legRight(y)
        let arc = bowlCenter.y + sqrt(max(0, bowlRadius * bowlRadius - (x - bowlCenter.x) * (x - bowlCenter.x)))
        if y < arc { lo = y } else { hi = y }
    }
    return CGPoint(x: legRight(lo), y: lo)
}
let notchRadius: CGFloat = 7

/// Cream parts: the stem, the bowl (a bar ending in a half circle) and the leg.
func creamShapes() -> [CGPath] {
    // The stem's top-right is inside the bowl; only its other three corners show.
    let stemBody = rounded([CGPoint(x: stemLeft, y: top), CGPoint(x: stemRight, y: top),
                            CGPoint(x: stemRight, y: bottom), CGPoint(x: stemLeft, y: bottom)],
                           [48, 0, 48, 48])
    let bowl = CGMutablePath()
    // The bar's underside shows only between stem and leg; beyond the leg the half circle forms the bowl.
    bowl.addRect(CGRect(x: stemLeft + 40, y: top, width: bowlCenter.x - stemLeft - 40, height: bowlCenter.y - top))
    bowl.addRect(CGRect(x: stemLeft + 40, y: top, width: notchTip().x - 4 - stemLeft - 40, height: barBottom - top))
    bowl.addEllipse(in: CGRect(x: bowlCenter.x - bowlRadius, y: bowlCenter.y - bowlRadius, width: bowlRadius * 2, height: bowlRadius * 2))
    // Under the bar, between stem and leg, so the opening's rounded corners leave fillets.
    let fillets = CGMutablePath()
    fillets.addLines(between: [CGPoint(x: stemRight - 1, y: barBottom - 1), CGPoint(x: legLeft(barBottom - 1) + 1, y: barBottom - 1),
                               CGPoint(x: legLeft(barBottom + 80) + 1, y: barBottom + 80), CGPoint(x: stemRight - 1, y: barBottom + 80)])
    fillets.closeSubpath()
    let legTop: CGFloat = 640
    let leg = rounded([CGPoint(x: legLeft(legTop), y: legTop), CGPoint(x: legLeft(bottom), y: bottom),
                       CGPoint(x: legRight(bottom), y: bottom), CGPoint(x: legRight(legTop), y: legTop)],
                      [0, 16, 41, 0])
    // Fill the sharp tip of the notch between bowl and leg; inkShapes rounds it again.
    let tip = notchTip(), reach = notchRadius / tan(23 * .pi / 180) + 2
    let notch = CGMutablePath()
    notch.addLines(between: [tip, CGPoint(x: tip.x + reach, y: tip.y - 1), CGPoint(x: legRight(tip.y + reach * 0.72), y: tip.y + reach * 0.72)])
    notch.closeSubpath()
    return [stemBody, bowl, fillets, leg, notch]
}

/// Black parts cut back out: the counter, the opening under the bowl and the notch's rounded tip.
func inkShapes() -> [CGPath] {
    // The counter: square-ish on the stem side, generously rounded where it meets the bowl.
    let counter = rounded([CGPoint(x: stemRight, y: 418), CGPoint(x: 794.7, y: 418),
                           CGPoint(x: 794.7, y: 599.7), CGPoint(x: stemRight, y: 599.7)],
                          [28, 80, 80, 28])
    // Under the bowl, between stem and leg. Its rounded top corners leave soft fillets.
    let deep: CGFloat = 1060
    let opening = rounded([CGPoint(x: stemRight, y: barBottom), CGPoint(x: legLeft(barBottom), y: barBottom),
                           CGPoint(x: legLeft(deep), y: deep), CGPoint(x: stemRight, y: deep)],
                          [20, 50, 0, 0])
    // The notch, from a small round tip outwards between the bowl's underside and the leg.
    let tip = notchTip()
    let along = CGVector(dx: 1, dy: 0), down = CGVector(dx: 0.956 / 1.3835, dy: 1 / 1.3835)
    let bisector = CGVector(dx: along.dx + down.dx, dy: along.dy + down.dy)
    let length = sqrt(bisector.dx * bisector.dx + bisector.dy * bisector.dy)
    let half = acos(along.dx * down.dx + along.dy * down.dy) / 2
    let distance = notchRadius / sin(half)
    let center = CGPoint(x: tip.x + bisector.dx / length * distance, y: tip.y + bisector.dy / length * distance)
    let notch = CGMutablePath()
    notch.addEllipse(in: CGRect(x: center.x - notchRadius, y: center.y - notchRadius, width: notchRadius * 2, height: notchRadius * 2))
    // Restore the bowl and leg around the round tip, so only the tip itself changes.
    return [counter, opening, notch]
}

/// Apple-style continuous corners: a superellipse with exponent 5.
func squircle(_ rect: CGRect) -> CGPath {
    let path = CGMutablePath(), steps = 720, n: CGFloat = 5
    let a = rect.width / 2, b = rect.height / 2
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n), y = b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        let p = CGPoint(x: rect.midX + x, y: rect.midY + y)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

/// Draws the tile and R into `tile`, given in a y-down context.
func drawMark(_ context: CGContext, tile: CGRect, drawTile: Bool = true) {
    if drawTile {
        context.addPath(squircle(tile)); context.setFillColor(ink); context.fillPath()
    }
    context.saveGState()
    context.addPath(squircle(tile)); context.clip()
    context.translateBy(x: tile.minX, y: tile.minY)
    context.scaleBy(x: tile.width / tileSide, y: tile.height / tileSide)
    context.translateBy(x: -tileOrigin, y: -tileOrigin)
    context.setFillColor(cream)
    for shape in creamShapes() { context.addPath(shape); context.fillPath() }
    context.setFillColor(ink)
    for shape in inkShapes() { context.addPath(shape); context.fillPath() }
    context.restoreGState()
}

// MARK: Output

func bitmap(_ width: Int, _ height: Int) -> CGContext {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work in y-down coordinates like the reference image.
    context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
    context.setShouldAntialias(true); context.interpolationQuality = .high
    return context
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "RailIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot write \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "RailIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG export failed: \(url.path)"])
    }
}

/// The macOS icon grid: an 824-point body centred in 1024, with a soft shadow below it.
func appIcon(_ pixels: Int) -> CGImage {
    let context = bitmap(pixels, pixels)
    let scale = CGFloat(pixels) / 1024
    let body = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    context.saveGState()
    // y is flipped, so a positive offset moves the shadow down on screen.
    context.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 12 * scale, color: CGColor(gray: 0, alpha: 0.28))
    context.addPath(squircle(body)); context.setFillColor(ink); context.fillPath()
    context.restoreGState()
    drawMark(context, tile: body, drawTile: false)
    return context.makeImage()!
}

// 1. App icon with all ten representations, each drawn at its own size.
let temporary = files.temporaryDirectory.appendingPathComponent("rail-icon-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try files.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try writePNG(appIcon(size * scale), to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run(); iconutil.waitUntilExit()
// Top-level defer runs straight away in scripts, so the temporary iconset is removed here.
try? files.removeItem(at: temporary)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

// 2. In-app mark: the tile fills a 64 × 64 pt page, as vectors.
var page = CGRect(x: 0, y: 0, width: 64, height: 64)
guard let pdf = CGContext(markPDF as CFURL, mediaBox: &page, nil) else { fatalError("Cannot write \(markPDF.path)") }
pdf.beginPDFPage(nil)
pdf.translateBy(x: 0, y: 64); pdf.scaleBy(x: 1, y: -1)
drawMark(pdf, tile: page)
pdf.endPDFPage(); pdf.closePDF()

// 3. Previews for review.
let master = appIcon(1024)
try writePNG(master, to: previews.appendingPathComponent("AppIcon-1024.png"))

// Contact sheet: 16, 32 and 128 at 1:1 (16 and 32 also enlarged 8× and 4×, nearest-neighbour), then 1024 halved.
let sheet = bitmap(1760, 620)
sheet.setFillColor(CGColor(gray: 0.93, alpha: 1)); sheet.fill(CGRect(x: 0, y: 0, width: 1760, height: 620))
var x: CGFloat = 30
for (size, zoom) in [(16, 8), (32, 4), (128, 1)] {
    let image = appIcon(size)
    // Actual pixels on top, the enlarged view underneath.
    sheet.saveGState(); sheet.translateBy(x: x, y: 30 + CGFloat(size)); sheet.scaleBy(x: 1, y: -1)
    sheet.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size)); sheet.restoreGState()
    let big = CGFloat(size * zoom)
    if zoom > 1 {
        sheet.saveGState(); sheet.interpolationQuality = .none
        sheet.translateBy(x: x, y: 200 + big); sheet.scaleBy(x: 1, y: -1)
        sheet.draw(image, in: CGRect(x: 0, y: 0, width: big, height: big)); sheet.restoreGState()
    }
    x += max(big, 128) + 40
}
sheet.saveGState(); sheet.translateBy(x: x, y: 30 + 512); sheet.scaleBy(x: 1, y: -1)
sheet.draw(master, in: CGRect(x: 0, y: 0, width: 512, height: 512)); sheet.restoreGState()
try writePNG(sheet.makeImage()!, to: previews.appendingPathComponent("AppIcon-sizes.png"))

// Overlay: where the reconstruction and the reference disagree. The reference is dimmed;
// red marks cream drawn where the reference is dark, blue marks reference cream that is missing.
guard let source = CGImageSourceCreateWithURL(reference as CFURL, nil),
      let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Cannot read \(reference.path)") }
let side = original.width
func pixels(_ draw: (CGContext) -> Void) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: side * side * 4)
    data.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
    }
    return data
}
let referencePixels = pixels { $0.draw(original, in: CGRect(x: 0, y: 0, width: side, height: side)) }
let reconstruction = pixels { context in
    context.translateBy(x: 0, y: CGFloat(side)); context.scaleBy(x: 1, y: -1)
    drawMark(context, tile: CGRect(x: tileOrigin, y: tileOrigin, width: tileSide, height: tileSide))
}
var diff = [UInt8](repeating: 255, count: side * side * 4)
var mismatched = 0, creamPixels = 0
for i in stride(from: 0, to: side * side * 4, by: 4) {
    let isCream = { (p: [UInt8]) in p[i] > 128 && p[i + 2] > 100 && Int(p[i]) > Int(p[i + 2]) + 20 }
    let a = isCream(referencePixels), b = isCream(reconstruction)
    if a { creamPixels += 1 }
    let grey = UInt8(150 + Int(referencePixels[i]) * 100 / 255)
    var rgb: (UInt8, UInt8, UInt8) = (grey, grey, grey)
    if b && !a { rgb = (230, 30, 30); mismatched += 1 } else if a && !b { rgb = (30, 80, 230); mismatched += 1 }
    diff[i] = rgb.0; diff[i + 1] = rgb.1; diff[i + 2] = rgb.2; diff[i + 3] = 255
}
let diffImage = diff.withUnsafeMutableBytes { buffer in
    CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}
try writePNG(diffImage, to: previews.appendingPathComponent("overlay-check.png"))
print(String(format: "Overlay: %d differing pixels, %.2f%% of the reference R's area.", mismatched, Double(mismatched) / Double(max(creamPixels, 1)) * 100))

print("Packaged \(icns.path) with all 10 macOS icon representations.")
print("Wrote \(markPDF.path) and previews in \(previews.path).")
