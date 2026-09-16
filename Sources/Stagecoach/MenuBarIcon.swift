// The menu bar mark: a stagecoach wheel, the same motif as the app icon.
//
// Drawn rather than stored, because the menu bar is small and unforgiving. At
// eighteen points a wheel with eight spokes turns into a grey smudge, so it has
// six, the rim is heavier than looks right at full size, and the hub is drawn
// solid to give the middle something to hold on to.
//
// It is a template image: the system paints it black on a light menu bar, white
// on a dark one, and dims it when the menu is open. Nothing here chooses a
// colour, which is why it looks right in both.

import AppKit

enum MenuBarIcon {
    /// The wheel, with a dot at its shoulder when something wants attention.
    static func image(needsAttention: Bool) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)

            let centre = CGPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 7.2
            let rim: CGFloat = 1.5

            ctx.setLineWidth(rim)
            ctx.addEllipse(in: CGRect(x: centre.x - radius + rim / 2, y: centre.y - radius + rim / 2,
                                      width: (radius - rim / 2) * 2, height: (radius - rim / 2) * 2))
            ctx.strokePath()

            // Six spokes, starting off-axis so none lies flat against the rim's
            // thinnest point, which is where a spoke disappears at this size.
            ctx.setLineWidth(1.1)
            let hub: CGFloat = 1.6
            for i in 0..<6 {
                let angle = CGFloat(i) / 6 * .pi * 2 + .pi / 12
                ctx.move(to: CGPoint(x: centre.x + cos(angle) * (hub - 0.3),
                                     y: centre.y + sin(angle) * (hub - 0.3)))
                ctx.addLine(to: CGPoint(x: centre.x + cos(angle) * (radius - rim),
                                        y: centre.y + sin(angle) * (radius - rim)))
            }
            ctx.strokePath()

            ctx.fillEllipse(in: CGRect(x: centre.x - hub, y: centre.y - hub, width: hub * 2, height: hub * 2))

            if needsAttention {
                // Punched out of the rim so the dot reads as separate from the
                // wheel rather than as a lump on it.
                let dot = CGPoint(x: rect.maxX - 2.6, y: rect.maxY - 2.6)
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: CGRect(x: dot.x - 2.9, y: dot.y - 2.9, width: 5.8, height: 5.8))
                ctx.setBlendMode(.normal)
                ctx.fillEllipse(in: CGRect(x: dot.x - 1.9, y: dot.y - 1.9, width: 3.8, height: 3.8))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
