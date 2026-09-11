// Lucid product film — 15s, 1920x1080, 60fps.
//
//   swiftc -O -o film media/Film.swift
//   ./film | ffmpeg -f rawvideo -pix_fmt bgra -s 1920x1080 -r 60 -i - … out.mp4
//   ./film --frame 6.4 shot.png        # one frame, for looking at
//
// Frames go to stdout as raw BGRA. NOTHING may print to stdout or the stream corrupts —
// every diagnostic goes to stderr.
//
// The whole film stays inside the screen: a Claude Code session, the app noticing it,
// then the case for the app. No laptop, no camera move.
//
// On the comparison at the end — every line of it is checked. Caffeine is a manual
// toggle with an optional timer. Amphetamine has a deep trigger list, closed-display
// mode included, and does not need a charger or a second display for it. What neither
// can do is separate "the agent is generating" from "the agent is waiting for you":
// the nearest triggers available are "this app is running", true for the whole session,
// and a CPU threshold, which a network-bound tool call defeats. That gap is the claim,
// and it is the only comparative claim the film makes.
import AppKit
import CoreGraphics
import CoreText
import Foundation

let W = 1920, H = 1080
let FPS = 60.0
let DURATION = 15.0

// ---------------------------------------------------------------------------------
// MARK: - colour and type

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}
func fade(_ c: CGColor, _ a: CGFloat) -> CGColor { c.copy(alpha: c.alpha * max(0, min(1, a)))! }

// Claude Code's palette, as it renders in a dark terminal.
let cTermBG = rgb(18, 18, 22)
let cText   = rgb(232, 232, 236)
let cDim    = rgb(124, 124, 136)
let cFaint  = rgb(78, 78, 88)
let cClaude = rgb(217, 119, 87)
let cGreen  = rgb(86, 200, 130)
let cBorder = rgb(58, 58, 68)

// The film's own palette.
let cRoom  = rgb(9, 10, 16)
let cWhite = rgb(242, 243, 247)
let cGrey  = rgb(140, 142, 155)
let cSeam  = rgb(140, 200, 255)

let mono  = { (s: CGFloat) in NSFont.monospacedSystemFont(ofSize: s, weight: .regular) as CTFont }
let monoB = { (s: CGFloat) in NSFont.monospacedSystemFont(ofSize: s, weight: .semibold) as CTFont }
let disp  = { (s: CGFloat, w: NSFont.Weight) in NSFont.systemFont(ofSize: s, weight: w) as CTFont }

let borelURL = URL(fileURLWithPath: "assets/fonts/Borel-Regular.ttf")

/// "lucid" as outlines, so it can be filled and glowed like any other shape.
let wordmark: CGPath = {
    let p = CGMutablePath()
    guard let ds = CTFontManagerCreateFontDescriptorsFromURL(borelURL as CFURL)
                    as? [CTFontDescriptor], let d = ds.first else {
        FileHandle.standardError.write("missing \(borelURL.path)\n".data(using: .utf8)!)
        return p
    }
    let f = CTFontCreateWithFontDescriptor(d, 200, nil)
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: "lucid", attributes: [.font: f]))
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let n = CTRunGetGlyphCount(run)
        var gs = [CGGlyph](repeating: 0, count: n), ps = [CGPoint](repeating: .zero, count: n)
        CTRunGetGlyphs(run, CFRangeMake(0, n), &gs)
        CTRunGetPositions(run, CFRangeMake(0, n), &ps)
        let rf = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont
        for i in 0..<n {
            if let g = CTFontCreatePathForGlyph(rf, gs[i], nil) {
                p.addPath(g, transform: CGAffineTransform(translationX: ps[i].x, y: ps[i].y))
            }
        }
    }
    return p
}()
let wmBounds = wordmark.boundingBoxOfPath

func draw(_ s: String, _ ctx: CGContext, x: CGFloat, y: CGFloat,
          font: CTFont, color: CGColor, alpha: CGFloat = 1) {
    guard alpha > 0.004, !s.isEmpty else { return }
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(
        string: s, attributes: [.font: font,
                                .foregroundColor: NSColor(cgColor: fade(color, alpha))!])), ctx)
}

func width(_ s: String, _ font: CTFont) -> CGFloat {
    CGFloat(CTLineGetTypographicBounds(
        CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font])),
        nil, nil, nil))
}

func drawCentred(_ s: String, _ ctx: CGContext, cx: CGFloat, y: CGFloat,
                 font: CTFont, color: CGColor, alpha: CGFloat = 1) {
    draw(s, ctx, x: cx - width(s, font) / 2, y: y, font: font, color: color, alpha: alpha)
}

/// A headline with one phrase in a second colour, laid out as one centred line.
func drawAccented(_ parts: [(String, CGColor)], _ ctx: CGContext, cx: CGFloat, y: CGFloat,
                  font: CTFont, alpha: CGFloat) {
    let total = parts.reduce(CGFloat(0)) { $0 + width($1.0, font) }
    var x = cx - total / 2
    for (s, c) in parts {
        draw(s, ctx, x: x, y: y, font: font, color: c, alpha: alpha)
        x += width(s, font)
    }
}

func drawWordmark(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, height h: CGFloat,
                  color: CGColor, alpha: CGFloat) {
    guard alpha > 0.004 else { return }
    let k = h / wmBounds.height
    ctx.saveGState()
    ctx.translateBy(x: cx - wmBounds.midX * k, y: cy - wmBounds.midY * k)
    ctx.scaleBy(x: k, y: k)
    ctx.addPath(wordmark)
    ctx.setFillColor(fade(color, alpha))
    ctx.fillPath()
    ctx.restoreGState()
}

// ---------------------------------------------------------------------------------
// MARK: - easing

func clamp(_ v: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { max(lo, min(hi, v)) }
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
func easeInOut(_ t: Double) -> Double { t < 0.5 ? 4*t*t*t : 1 - pow(-2*t + 2, 3) / 2 }
/// Fades in, holds, fades out — the shape every caption in here needs.
func envelope(_ t: Double, _ a: Double, _ b: Double,
              _ tIn: Double = 0.3, _ tOut: Double = 0.3) -> Double {
    min(ramp(t, a, a + tIn), 1 - ramp(t, b - tOut, b))
}

// ---------------------------------------------------------------------------------
// MARK: - timeline

let tTypeFrom = 0.55, tTypeTo = 2.45
let tSubmit   = 2.65
let tPanel    = 3.90, tPanelEnd = 5.15
let tFeat     = 5.15                    // four feature cards, back to back
let featStep  = 1.10
let tVersus   = 9.65, tVersusEnd = 13.00
let tBrand    = 13.05

let promptText = "refactor the auth layer and run the tests"

enum Row { case tool(String), result(String, CGColor), blank }
let transcript: [(at: Double, row: Row)] = [
    (2.95, .tool("Read(src/auth/session.ts)")),
    (3.22, .result("Read 412 lines", cDim)),
    (3.42, .blank),
    (3.55, .tool("Bash(npm test)")),
    (3.80, .result("Running…", cDim)),
]

let features: [[(String, CGColor)]] = [
    [("It reads the agent's ", cWhite), ("own hooks", cSeam), (".", cWhite)],
    [("Lid shut. ", cWhite), ("No charger. No second display.", cGrey)],
    [("Sleeps the moment the agent ", cWhite), ("stops", cSeam), (".", cWhite)],
    [("Battery, thermal and time — ", cWhite), ("all guarded", cSeam), (".", cWhite)],
]

// ---------------------------------------------------------------------------------
// MARK: - Claude Code screen
//
// Claude Code's ⏺ ⎿ ✻ are drawn as vectors, not set as text. SF Mono does not carry
// all of them and a font fallback at this scale is instantly visible as wrong.

func claudeAsterisk(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat,
                    color: CGColor, alpha: CGFloat) {
    guard alpha > 0.004 else { return }
    ctx.saveGState()
    ctx.setStrokeColor(fade(color, alpha))
    ctx.setLineWidth(r * 0.34)
    ctx.setLineCap(.round)
    for i in 0..<3 {
        let a = Double(i) * .pi / 3 + .pi / 6
        ctx.move(to: CGPoint(x: cx - cos(a) * r, y: cy - sin(a) * r))
        ctx.addLine(to: CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r))
    }
    ctx.strokePath()
    ctx.restoreGState()
}

/// The ⎿ that hangs a tool result under its call.
func resultElbow(_ ctx: CGContext, x: CGFloat, top: CGFloat, bottom: CGFloat,
                 run: CGFloat, alpha: CGFloat) {
    guard alpha > 0.004 else { return }
    ctx.saveGState()
    ctx.setStrokeColor(fade(cFaint, alpha))
    ctx.setLineWidth(2.5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: x, y: top))
    ctx.addLine(to: CGPoint(x: x, y: bottom))
    ctx.addLine(to: CGPoint(x: x + run, y: bottom))
    ctx.strokePath()
    ctx.restoreGState()
}

func drawClaudeScreen(_ ctx: CGContext, t: Double, alpha: CGFloat) {
    guard alpha > 0.004 else { return }
    ctx.saveGState()
    ctx.setFillColor(fade(cTermBG, alpha))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))

    let fs: CGFloat = 30, lh: CGFloat = 46
    let f = mono(fs), fb = monoB(fs)
    let left: CGFloat = 210
    var y: CGFloat = 890

    // ---- welcome box ----------------------------------------------------------
    let box = CGRect(x: left, y: y - 150, width: CGFloat(W) - left * 2, height: 196)
    ctx.saveGState()
    ctx.setStrokeColor(fade(cBorder, alpha))
    ctx.setLineWidth(2)
    ctx.addPath(CGPath(roundedRect: box, cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.strokePath()
    ctx.restoreGState()
    claudeAsterisk(ctx, cx: box.minX + 40, cy: box.maxY - 44, r: 12, color: cClaude, alpha: alpha)
    draw("Welcome to Claude Code", ctx, x: box.minX + 68, y: box.maxY - 54, font: fb,
         color: cText, alpha: alpha)
    draw("cwd: /Users/dev/projects/api", ctx, x: box.minX + 68, y: box.maxY - 54 - lh * 1.7,
         font: f, color: cDim, alpha: alpha)
    y = box.minY - 76

    // ---- the prompt, typing ----------------------------------------------------
    let typed = Int(round(Double(promptText.count) * easeOut(ramp(t, tTypeFrom, tTypeTo))))
    let shown = String(promptText.prefix(max(0, typed)))
    draw(">", ctx, x: left, y: y, font: f, color: cText, alpha: alpha)
    let px = left + width("> ", f)
    draw(shown, ctx, x: px, y: y, font: f, color: cText, alpha: alpha)
    if t < tSubmit, t > tTypeFrom - 0.4, Int(t * 2.2) % 2 == 0 {
        ctx.setFillColor(fade(cText, alpha * 0.85))
        ctx.fill(CGRect(x: px + width(shown, f), y: y - 7, width: width("M", f), height: fs))
    }
    y -= lh * 1.8

    // ---- transcript ------------------------------------------------------------
    for e in transcript {
        guard t >= e.at else { break }
        let a = alpha * CGFloat(ramp(t, e.at, e.at + 0.18))
        switch e.row {
        case .blank:
            y -= lh * 0.45
        case .tool(let s):
            ctx.setFillColor(fade(cText, a))
            ctx.fillEllipse(in: CGRect(x: left + 2, y: y + 8, width: 13, height: 13))
            draw(s, ctx, x: left + 34, y: y, font: fb, color: cText, alpha: a)
            y -= lh
        case .result(let s, let c):
            resultElbow(ctx, x: left + 40, top: y + lh * 0.7, bottom: y + 10, run: 18, alpha: a)
            draw(s, ctx, x: left + 76, y: y, font: f, color: c, alpha: a)
            y -= lh
        }
    }

    // ---- the working line ------------------------------------------------------
    if t > tSubmit {
        let a = alpha * CGFloat(ramp(t, tSubmit, tSubmit + 0.25))
        ctx.saveGState()
        ctx.translateBy(x: left + 9, y: y - lh * 0.15 + 11)
        ctx.rotate(by: t * 2.6)
        claudeAsterisk(ctx, cx: 0, cy: 0, r: 11, color: cClaude, alpha: a)
        ctx.restoreGState()
        draw("Working… (\(Int(t - tSubmit) + 6)s · ↑ 2.1k tokens · esc to interrupt)", ctx,
             x: left + 34, y: y - lh * 0.15, font: f, color: cDim, alpha: a)
    }
    ctx.restoreGState()
}

// ---------------------------------------------------------------------------------
// MARK: - the app noticing

/// The menu bar panel, as it actually reads: agent, state, and what that is buying you.
func drawPanel(_ ctx: CGContext, t: Double, alpha: CGFloat) {
    guard alpha > 0.004 else { return }
    // Rises a little as it arrives, so it lands rather than appears.
    let rise = CGFloat(lerp(34, 0, easeOut(ramp(t, tPanel, tPanel + 0.55))))
    let card = CGRect(x: CGFloat(W)/2 - 330, y: 132 - rise, width: 660, height: 186)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 50, color: rgb(0, 0, 0, 0.7 * alpha))
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.setFillColor(fade(rgb(32, 34, 42), alpha))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setStrokeColor(fade(rgb(72, 76, 92), alpha))
    ctx.setLineWidth(1.5)
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.strokePath()
    ctx.restoreGState()

    drawWordmark(ctx, cx: card.minX + 74, cy: card.maxY - 42, height: 30,
                 color: cWhite, alpha: alpha)

    // Session row.
    let dotA = alpha * CGFloat(0.65 + 0.35 * sin(t * 5.0))
    ctx.setFillColor(fade(cGreen, dotA))
    ctx.fillEllipse(in: CGRect(x: card.minX + 42, y: card.midY - 22, width: 16, height: 16))
    draw("Claude Code", ctx, x: card.minX + 74, y: card.midY - 22, font: disp(30, .medium),
         color: cWhite, alpha: alpha)
    let st = "Working"
    draw(st, ctx, x: card.maxX - 42 - width(st, disp(30, .medium)), y: card.midY - 22,
         font: disp(30, .medium), color: cGreen, alpha: alpha)
    draw("lid shut · staying awake", ctx, x: card.minX + 74, y: card.minY + 34,
         font: disp(24, .regular), color: cGrey, alpha: alpha)
}

// ---------------------------------------------------------------------------------
// MARK: - frame

func renderFrame(_ ctx: CGContext, t: Double) {
    ctx.setFillColor(cRoom)
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))

    // The terminal holds the frame, then recedes behind everything that follows.
    // Drops to a faint texture behind the feature cards, then leaves entirely — the
    // comparison is an argument and wants nothing competing with it.
    let screenA = CGFloat((1 - ramp(t, tFeat - 0.45, tFeat + 0.25) * 0.975)
                          * (1 - ramp(t, tVersus - 1.0, tVersus - 0.2)))
    drawClaudeScreen(ctx, t: t, alpha: screenA)

    drawPanel(ctx, t: t, alpha: CGFloat(envelope(t, tPanel, tPanelEnd + 0.4, 0.45, 0.5)))

    let midX = CGFloat(W) / 2

    // ---- feature cards ---------------------------------------------------------
    for (i, parts) in features.enumerated() {
        let a = tFeat + Double(i) * featStep
        let alpha = CGFloat(envelope(t, a, a + featStep, 0.26, 0.26))
        guard alpha > 0.004 else { continue }
        // Each line drifts up a few pixels as it lands — the only motion it needs.
        let dy = CGFloat(lerp(14, 0, easeOut(ramp(t, a, a + 0.5))))
        drawAccented(parts, ctx, cx: midX, y: 520 - dy, font: disp(58, .medium), alpha: alpha)
    }
    // Progress rule under the montage, so the run of cards reads as one passage.
    let runA = CGFloat(envelope(t, tFeat, tFeat + featStep * 4, 0.3, 0.3))
    if runA > 0.004 {
        let w: CGFloat = 420
        ctx.setFillColor(fade(rgb(70, 74, 92), runA))
        ctx.fill(CGRect(x: midX - w/2, y: 398, width: w, height: 3))
        ctx.setFillColor(fade(cSeam, runA))
        ctx.fill(CGRect(x: midX - w/2, y: 398,
                        width: w * CGFloat(ramp(t, tFeat, tFeat + featStep * 4)), height: 3))
    }

    // ---- the comparison --------------------------------------------------------
    let vA = CGFloat(envelope(t, tVersus, tVersusEnd, 0.4, 0.45))
    if vA > 0.004 {
        let rows: [(String, String, CGColor, Double)] = [
            ("Caffeine",    "is a switch.",             cGrey,  0.10),
            ("Amphetamine", "watches CPU.",             cGrey,  0.75),
            ("lucid",       "listens to the agent.",    cWhite, 1.45),
        ]
        let fName = disp(52, .semibold), fRest = disp(52, .regular)
        // One shared two-column layout: names right-aligned into a gutter, predicates
        // left-aligned out of it. Centring each row on its own would stagger the three
        // claims and lose the fact that they are the same sentence three times.
        let gutter: CGFloat = 44
        let nameW = rows.map { $0.0 == "lucid" ? 130 : width($0.0, fName) }.max()!
        let restW = rows.map { width($0.1, fRest) }.max()!
        let x0 = midX - (nameW + gutter + restW) / 2
        for (i, r) in rows.enumerated() {
            let a = vA * CGFloat(ramp(t, tVersus + r.3, tVersus + r.3 + 0.45))
            guard a > 0.004 else { continue }
            let y = CGFloat(648 - i * 112)
            if r.0 == "lucid" {
                drawWordmark(ctx, cx: x0 + nameW - 65, cy: y + 20, height: 46,
                             color: cWhite, alpha: a)
            } else {
                draw(r.0, ctx, x: x0 + nameW - width(r.0, fName), y: y, font: fName,
                     color: r.2, alpha: a)
            }
            draw(r.1, ctx, x: x0 + nameW + gutter, y: y, font: fRest, color: r.2, alpha: a)
        }
    }

    // ---- brand -----------------------------------------------------------------
    let bA = CGFloat(min(ramp(t, tBrand, tBrand + 0.6), 1 - ramp(t, DURATION - 0.9, DURATION)))
    if bA > 0.004 {
        let k = CGFloat(lerp(1.05, 1.0, easeOut(ramp(t, tBrand, tBrand + 0.9))))
        ctx.saveGState()
        ctx.translateBy(x: midX, y: 590)
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -midX, y: -590)
        ctx.setShadow(offset: .zero, blur: 44, color: fade(rgb(130, 186, 255), bA * 0.5))
        drawWordmark(ctx, cx: midX, cy: 590, height: 190, color: cWhite, alpha: bA)
        ctx.restoreGState()
        drawCentred("Looks asleep. Isn't.", ctx, cx: midX, y: 420, font: disp(42, .regular),
                    color: cGrey, alpha: bA * CGFloat(ramp(t, tBrand + 0.45, tBrand + 1.1)))
    }

    // ---- open and close on black ------------------------------------------------
    let blackA = max(1 - ramp(t, 0, 0.4), ramp(t, DURATION - 0.6, DURATION))
    if blackA > 0.004 {
        ctx.setFillColor(rgb(0, 0, 0, CGFloat(blackA)))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))
    }
}

// ---------------------------------------------------------------------------------
// MARK: - output

func newContext() -> CGContext {
    CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue)!
}

let argv = CommandLine.arguments
if let i = argv.firstIndex(of: "--frame"), i + 2 < argv.count {
    let ctx = newContext()
    renderFrame(ctx, t: Double(argv[i + 1]) ?? 0)
    try NSBitmapImageRep(cgImage: ctx.makeImage()!)
        .representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: argv[i + 2]))
    FileHandle.standardError.write("frame written\n".data(using: .utf8)!)
    exit(0)
}

let ctx = newContext()
let out = FileHandle.standardOutput
let total = Int(DURATION * FPS)
for n in 0..<total {
    renderFrame(ctx, t: Double(n) / FPS)
    out.write(Data(bytes: ctx.data!, count: W * H * 4))
    if n % 120 == 0 { FileHandle.standardError.write("\(n)/\(total)\n".data(using: .utf8)!) }
}
