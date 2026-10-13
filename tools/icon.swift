// Renders the app icon variants. Usage: swift tools/icon.swift ios/UnoWheel/Assets.xcassets/AppIcon.appiconset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Variant: String { case light, dark, tinted }

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func render(_ v: Variant, to path: String) {
    let s: CGFloat = 1024
    let ctx = CGContext(data: nil, width: Int(s), height: Int(s), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Background
    switch v {
    case .light:
        let g = CGGradient(colorsSpace: space, colors: [color(0xFF8A3D), color(0xF2416B)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    case .dark:
        let g = CGGradient(colorsSpace: space, colors: [color(0x23202A), color(0x121016)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    case .tinted:
        ctx.setFillColor(color(0x000000))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    }

    let center = CGPoint(x: s / 2, y: s / 2 - 20)
    let ink: CGColor = v == .light ? color(0xFFFFFF) : v == .dark ? color(0xFF7A45) : color(0xFFFFFF, 0.62)
    let deck: CGColor = v == .light ? color(0x1C1A22) : v == .dark ? color(0xF4F1F7) : color(0xFFFFFF)

    let rimColor: CGColor = v == .light ? color(0xFFFFFF, 0.28) : v == .dark ? color(0xFF7A45, 0.25) : color(0xFFFFFF, 0.22)
    let tireR: CGFloat = 270
    let holeR: CGFloat = 150

    // Ground shadow, kissing the bottom of the tire
    if v != .tinted {
        ctx.setFillColor(color(0x000000, v == .light ? 0.18 : 0.4))
        ctx.fillEllipse(in: CGRect(x: center.x - 220, y: center.y - tireR - 26, width: 440, height: 44))
    }

    // Fat tire as an even-odd ring
    let ring = CGMutablePath()
    ring.addEllipse(in: CGRect(x: center.x - tireR, y: center.y - tireR, width: 2 * tireR, height: 2 * tireR))
    ring.addEllipse(in: CGRect(x: center.x - holeR, y: center.y - holeR, width: 2 * holeR, height: 2 * holeR))
    ctx.addPath(ring)
    ctx.setFillColor(ink)
    ctx.fillPath(using: .evenOdd)

    // Rim inside the tire
    ctx.setFillColor(rimColor)
    ctx.fillEllipse(in: CGRect(x: center.x - holeR, y: center.y - holeR, width: 2 * holeR, height: 2 * holeR))

    // Deck: flat through the hub, with kicked-up nose and tail
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y + 6)
    ctx.rotate(by: 0.2)
    let deckPath = CGMutablePath()
    deckPath.move(to: CGPoint(x: -400, y: 58))
    deckPath.addQuadCurve(to: CGPoint(x: -300, y: 0), control: CGPoint(x: -372, y: 4))
    deckPath.addLine(to: CGPoint(x: 300, y: 0))
    deckPath.addQuadCurve(to: CGPoint(x: 400, y: 58), control: CGPoint(x: 372, y: 4))
    ctx.addPath(deckPath)
    ctx.setStrokeColor(deck)
    ctx.setLineWidth(64)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Hub cap
    ctx.setFillColor(deck)
    ctx.fillEllipse(in: CGRect(x: -70, y: -70, width: 140, height: 140))
    ctx.setFillColor(ink)
    ctx.fillEllipse(in: CGRect(x: -28, y: -28, width: 56, height: 56))
    ctx.restoreGState()

    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ios/UnoWheel/Assets.xcassets/AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for v in [Variant.light, .dark, .tinted] { render(v, to: "\(out)/AppIcon-\(v.rawValue).png") }
