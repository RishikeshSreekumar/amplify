// Renders Amplify artwork: icon_1024.png, logo.png, logo-dark.png
// Usage: swift make_art.swift <outdir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

func render(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ name: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}

func linear(_ ctx: CGContext, _ colors: [NSColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ ctx: CGContext, _ colors: [NSColor], at c: CGPoint, r: CGFloat) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
}

/// Draws the full icon into a 1024x1024 coordinate space.
func drawIcon(_ ctx: CGContext) {
    // Squircle tile (macOS icon grid: 824pt tile inset 100pt).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: hex(0x000000, 0.35).cgColor)
    ctx.addPath(tilePath); ctx.setFillColor(hex(0x16123A).cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()

    // Deep night-club backdrop with a hot glow where the sound comes out.
    linear(ctx, [hex(0x241B5E), hex(0x120E30)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    radial(ctx, [hex(0xFF4F8B, 0.55), hex(0xFF4F8B, 0)], at: CGPoint(x: 600, y: 512), r: 520)

    // Level meter bars along the bottom, rising left to right.
    let bars: [(CGFloat, UInt32)] = [(70, 0x3FD7A5), (110, 0x3FD7A5), (150, 0x9BE15D), (190, 0xF9D648), (240, 0xFF9B42), (300, 0xFF4F6E)]
    for (i, (h, color)) in bars.enumerated() {
        let x = 196 + CGFloat(i) * 110
        let r = CGRect(x: x, y: 160, width: 80, height: h)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 18, cornerHeight: 18, transform: nil))
        ctx.setFillColor(hex(color, 0.22).cgColor); ctx.fillPath()
    }

    // Speaker: box + cone.
    let speaker = CGMutablePath()
    speaker.move(to: CGPoint(x: 230, y: 452))
    speaker.addLine(to: CGPoint(x: 330, y: 452))
    speaker.addLine(to: CGPoint(x: 470, y: 340))
    speaker.addLine(to: CGPoint(x: 470, y: 784))
    speaker.addLine(to: CGPoint(x: 330, y: 672))
    speaker.addLine(to: CGPoint(x: 230, y: 672))
    speaker.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: hex(0x000000, 0.45).cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(hex(0xFFFFFF).cgColor); ctx.setStrokeColor(hex(0xFFFFFF).cgColor)
    ctx.setLineWidth(44); ctx.setLineJoin(.round)
    ctx.addPath(speaker); ctx.drawPath(using: .fillStroke)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Sound waves, growing and heating up: the last one is the boost.
    let center = CGPoint(x: 470, y: 562)
    let waves: [(CGFloat, CGFloat, [NSColor])] = [
        (120, 40, [hex(0xFFFFFF), hex(0xFFFFFF)]),
        (230, 44, [hex(0xFFD86B), hex(0xFF9B42)]),
        (345, 50, [hex(0xFF7A59), hex(0xFF3D7F)]),
    ]
    for (radius, width, colors) in waves {
        let arc = CGMutablePath()
        arc.addArc(center: center, radius: radius, startAngle: -.pi / 4.2, endAngle: .pi / 4.2, clockwise: false)
        let stroke = arc.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 30, color: colors[1].withAlphaComponent(0.8).cgColor)
        ctx.addPath(stroke); ctx.setFillColor(colors[1].cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(stroke); ctx.clip()
        linear(ctx, colors, from: CGPoint(x: center.x, y: center.y + radius), to: CGPoint(x: center.x, y: center.y - radius))
        ctx.restoreGState()
    }

    ctx.restoreGState()

    // Tile edge highlight.
    ctx.addPath(tilePath)
    ctx.setStrokeColor(hex(0xFFFFFF, 0.18).cgColor); ctx.setLineWidth(4); ctx.strokePath()
}

// Icon
save(render(1024, 1024, drawIcon), "icon_1024.png")

// Logo: icon mark + rounded wordmark.
func drawLogo(dark: Bool) -> NSBitmapImageRep {
    render(1820, 560) { ctx in
        ctx.saveGState()
        ctx.translateBy(x: 0, y: 8)
        ctx.scaleBy(x: 0.53, y: 0.53)
        drawIcon(ctx)
        ctx.restoreGState()

        let base = NSFont.systemFont(ofSize: 220, weight: .heavy)
        let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded)!, size: 220)!
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Ampli", attributes: [.font: font, .foregroundColor: dark ? hex(0xF4EFE6) : hex(0x241B5E), .kern: -4]))
        text.append(NSAttributedString(string: "fy", attributes: [.font: font, .foregroundColor: hex(0xFF3D7F), .kern: -4]))
        let size = text.size()
        text.draw(at: CGPoint(x: 560, y: (560 - size.height) / 2 + 12))

        let tagFont = NSFont(descriptor: NSFont.systemFont(ofSize: 54, weight: .semibold).fontDescriptor.withDesign(.rounded)!, size: 54)!
        NSAttributedString(string: "turn your Mac past 100%", attributes: [
            .font: tagFont, .foregroundColor: dark ? hex(0xF4EFE6, 0.6) : hex(0x241B5E, 0.55), .kern: 1,
        ]).draw(at: CGPoint(x: 572, y: 96))
    }
}
save(drawLogo(dark: false), "logo.png")
save(drawLogo(dark: true), "logo-dark.png")
print("ok")
