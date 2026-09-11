// The Lucid wordmark: "lucid" set in Borel, the monoline handwriting face.
//
//   swift tools/wordmark.swift --png <path> [h] [--color RRGGBB]   transparent wordmark
//   swift tools/wordmark.swift --proof <path>             proof at several sizes
//   swift tools/wordmark.swift --iconset [sheet.png]      build/AppIcon.iconset
//
// Borel is SIL OFL 1.1 — assets/fonts/OFL.txt travels with it, which is the whole of
// the obligation. It is the right face here because it is genuinely monoline: uniform
// stroke, round caps, open loops. Every script font that ships with macOS has thick/thin
// contrast (Snell, Zapfino, Savoye) or is disconnected print-hand (Bradley, Noteworthy).
//
// The word is converted to a CGPath rather than drawn as text, so callers can fill it,
// glow it and scale it freely without the renderer hinting it differently at each size.
import AppKit
import CoreGraphics
import CoreText
import Foundation

let fontURL = URL(fileURLWithPath: "assets/fonts/Borel-Regular.ttf")

func loadFont(_ size: CGFloat) -> CTFont {
    guard let ds = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL)
                    as? [CTFontDescriptor], let d = ds.first else {
        FileHandle.standardError.write("cannot read \(fontURL.path)\n".data(using: .utf8)!)
        exit(1)
    }
    return CTFontCreateWithFontDescriptor(d, size, nil)
}

/// The word as outlines, baseline at y=0, starting at x=0.
func wordmarkPath(_ text: String = "lucid") -> CGPath {
    let attr = NSAttributedString(string: text, attributes: [.font: loadFont(200)])
    let line = CTLineCreateWithAttributedString(attr)
    let out = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let n = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: n)
        var pos = [CGPoint](repeating: .zero, count: n)
        CTRunGetGlyphs(run, CFRangeMake(0, n), &glyphs)
        CTRunGetPositions(run, CFRangeMake(0, n), &pos)
        let attrs = CTRunGetAttributes(run) as NSDictionary
        let runFont = attrs[kCTFontAttributeName as String] as! CTFont
        for i in 0..<n {
            guard let g = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
            out.addPath(g, transform: CGAffineTransform(translationX: pos[i].x, y: pos[i].y))
        }
    }
    return out
}

let markPath = wordmarkPath()
let markBounds = markPath.boundingBoxOfPath

/// Draws the wordmark to fit `rect`, preserving aspect and centring inside it.
func drawWordmark(_ ctx: CGContext, in rect: CGRect, color: CGColor) {
    let b = markBounds
    let k = min(rect.width / b.width, rect.height / b.height)
    ctx.saveGState()
    ctx.translateBy(x: rect.midX - b.midX * k, y: rect.midY - b.midY * k)
    ctx.scaleBy(x: k, y: k)
    ctx.addPath(markPath)
    ctx.setFillColor(color)
    ctx.fillPath()
    ctx.restoreGState()
}

func image(_ w: Int, _ h: Int, _ body: (CGContext) -> Void) -> Data {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    body(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!)
        .representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments

/// Fill colour for `--png`, given as RRGGBB. Defaults to white, which is what the film
/// and the dark-theme readme header want; the light-theme header passes a near-black.
let inkColor: CGColor = {
    guard let i = args.firstIndex(of: "--color"), i + 1 < args.count,
          let v = Int(args[i + 1], radix: 16) else { return CGColor(gray: 1, alpha: 1) }
    return CGColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                   green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}()

// ---- transparent wordmark, for the film and the readme ---------------------------
if let i = args.firstIndex(of: "--png"), i + 1 < args.count {
    let h = i + 2 < args.count ? CGFloat(Int(args[i + 2]) ?? 400) : 400
    let w = markBounds.width / markBounds.height * h
    let pad = h * 0.1
    let data = image(Int(w + pad * 2), Int(h + pad * 2)) { ctx in
        drawWordmark(ctx, in: CGRect(x: pad, y: pad, width: w, height: h), color: inkColor)
    }
    try data.write(to: URL(fileURLWithPath: args[i + 1]))
    print("wordmark \(Int(w + pad * 2))x\(Int(h + pad * 2))")
}

// ---- proof sheet -----------------------------------------------------------------
if let i = args.firstIndex(of: "--proof"), i + 1 < args.count {
    let W = 1500, H = 760
    let b = markBounds
    let data = image(W, H) { ctx in
        ctx.setFillColor(CGColor(red: 0.055, green: 0.06, blue: 0.09, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        drawWordmark(ctx, in: CGRect(x: 150, y: 290, width: b.width / b.height * 340,
                                     height: 340), color: CGColor(gray: 1, alpha: 1))
        for (n, h) in [CGFloat(80), 48, 28].enumerated() {
            drawWordmark(ctx, in: CGRect(x: 150 + CGFloat(n) * 340, y: 120,
                                         width: b.width / b.height * h, height: h),
                         color: CGColor(gray: 1, alpha: 1))
        }
    }
    try data.write(to: URL(fileURLWithPath: args[i + 1]))
    print("proof written")
}

// ---- app icon: the wordmark on the macOS squircle plate ---------------------------
// Apple's Big Sur grid: 824pt of artwork inside a 1024pt canvas, corner radius 185.4.
if args.contains("--iconset") {
    func plateIcon(_ px: Int) -> Data {
        image(px, px) { ctx in
            let size = CGFloat(px), inset = size * 100 / 1024
            let plate = CGRect(x: inset, y: inset,
                               width: size - inset * 2, height: size - inset * 2)
            let platePath = CGPath(roundedRect: plate, cornerWidth: size * 185.4 / 1024,
                                   cornerHeight: size * 185.4 / 1024, transform: nil)
            ctx.saveGState()
            ctx.addPath(platePath)
            ctx.clip()
            let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: [CGColor(red: 0.16, green: 0.18, blue: 0.33, alpha: 1),
                                         CGColor(red: 0.07, green: 0.08, blue: 0.17, alpha: 1),
                                         CGColor(red: 0.03, green: 0.03, blue: 0.07, alpha: 1)]
                                    as CFArray, locations: [0, 0.55, 1])!
            ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: plate.maxY),
                                   end: CGPoint(x: 0, y: plate.minY), options: [])

            // Optical centre sits a little above the geometric one — a wordmark hung
            // dead centre always looks like it has slipped downward.
            let w = plate.width * 0.74
            let h = w / markBounds.width * markBounds.height
            let box = CGRect(x: plate.midX - w / 2, y: plate.midY - h / 2 + size * 0.012,
                             width: w, height: h)
            ctx.setShadow(offset: .zero, blur: size * 0.05,
                          color: CGColor(red: 0.52, green: 0.74, blue: 1, alpha: 0.55))
            drawWordmark(ctx, in: box, color: CGColor(gray: 1, alpha: 1))
            ctx.restoreGState()

            // Top bevel: the light edge where the plate meets the air.
            ctx.saveGState()
            ctx.setLineWidth(size * 3 / 1024)
            ctx.addPath(platePath)
            ctx.clip()
            ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: size * 1.5 / 1024,
                                                          dy: size * 1.5 / 1024),
                               cornerWidth: size * 184 / 1024, cornerHeight: size * 184 / 1024,
                               transform: nil))
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            let bevel = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: [CGColor(gray: 1, alpha: 0.36),
                                            CGColor(gray: 1, alpha: 0.04),
                                            CGColor(gray: 1, alpha: 0)] as CFArray,
                                   locations: [0, 0.35, 1])!
            ctx.drawLinearGradient(bevel, start: CGPoint(x: 0, y: plate.maxY),
                                   end: CGPoint(x: 0, y: plate.minY), options: [])
            ctx.restoreGState()
        }
    }

    let out = URL(fileURLWithPath: "build/AppIcon.iconset")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let sizes: [(Int, String)] = [
        (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
        (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
        (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x"),
    ]
    for (px, name) in sizes {
        try plateIcon(px).write(to: out.appendingPathComponent("\(name).png"))
    }

    // Contact sheet, magnified nearest-neighbour so downscaling damage stays visible.
    if let i = args.firstIndex(of: "--iconset"), i + 1 < args.count,
       !args[i + 1].hasPrefix("--") {
        let shown = [16, 32, 64, 128, 256], cell = 300, pad = 24
        let W = pad + shown.count * (cell + pad), H = cell + pad * 2
        let sheet = image(W, H) { ctx in
            ctx.setFillColor(CGColor(gray: 0.49, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            ctx.interpolationQuality = .none
            for (n, px) in shown.enumerated() {
                let img = NSBitmapImageRep(data: plateIcon(px))!.cgImage!
                ctx.draw(img, in: CGRect(x: pad + n * (cell + pad), y: pad,
                                         width: cell, height: cell))
            }
        }
        try sheet.write(to: URL(fileURLWithPath: args[i + 1]))
    }
    print("wrote \(sizes.count) sizes to \(out.path)")
}
