// Draws the app icon: a stagecoach wheel — a rim, a hub, and eight spokes — in
// lamplight gold on a near-black tile, on Apple's macOS icon grid (an 824-point
// tile centred on a 1024-point canvas). Redrawn per size; strokes thicken as
// the icon shrinks so the wheel still reads at 16 points.
//
// Usage: make_icon <output.iconset>      (then: iconutil -c icns <output.iconset>)

import CoreGraphics
import Foundation
import ImageIO

func draw(pixels: Int, points: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)

    // Tile.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let corner: CGFloat = 824 * 0.2237
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.setFillColor(CGColor(red: 0.09, green: 0.075, blue: 0.07, alpha: 1))
    ctx.fillPath()

    // Wheel geometry, thicker at small sizes.
    let gold = CGColor(red: 0.85, green: 0.68, blue: 0.32, alpha: 1)
    let centre = CGPoint(x: 512, y: 512)
    let (rimR, rimW, hubR, spokeW): (CGFloat, CGFloat, CGFloat, CGFloat)
    switch points {
    case ...16: (rimR, rimW, hubR, spokeW) = (250, 110, 95, 80)
    case ...32: (rimR, rimW, hubR, spokeW) = (265, 80, 80, 58)
    default:    (rimR, rimW, hubR, spokeW) = (280, 52, 66, 38)
    }
    ctx.setStrokeColor(gold)
    ctx.setFillColor(gold)
    ctx.setLineCap(.round)

    ctx.setLineWidth(rimW)
    ctx.addEllipse(in: CGRect(x: centre.x - rimR, y: centre.y - rimR, width: rimR * 2, height: rimR * 2))
    ctx.strokePath()

    ctx.setLineWidth(spokeW)
    let spokes = points <= 16 ? 4 : 8
    for i in 0..<spokes {
        let a = CGFloat(i) / CGFloat(spokes) * .pi * 2 + .pi / 8
        ctx.move(to: CGPoint(x: centre.x + cos(a) * hubR, y: centre.y + sin(a) * hubR))
        ctx.addLine(to: CGPoint(x: centre.x + cos(a) * (rimR - rimW / 2), y: centre.y + sin(a) * (rimR - rimW / 2)))
    }
    ctx.strokePath()

    ctx.fillEllipse(in: CGRect(x: centre.x - hubR, y: centre.y - hubR, width: hubR * 2, height: hubR * 2))
    return ctx.makeImage()!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    let img = draw(pixels: points * scale, points: points)
    let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}
