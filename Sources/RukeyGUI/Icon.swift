import AppKit

/// Draws Rukey's lightning glyph.
///
/// The bolt is a tapered zigzag built once as a `CGPath` in an 18×18 pt box and
/// rendered in two variants: the menu-bar template (black with alpha, marked
/// `isTemplate`, so macOS inverts it for light and dark menu bars by itself —
/// there is deliberately no appearance observation here) and the outlined flash
/// variant the status item swaps in for a second when a word is learned.
/// Nothing reads icon data from disk — the icon is always drawn in code.
public enum Icon {
    /// The menu-bar canvas; the status item expects an 18×18 pt image.
    public static let size = NSSize(width: 18, height: 18)

    /// Stroke width of the bolt, in points: thick enough to read at menu-bar
    /// size, thin enough that the fill and the outline stay distinguishable.
    private static let strokeWidth: CGFloat = 1.6

    /// The bolt outline in the 18×18 box, in AppKit (y-up) coordinates.
    ///
    /// Six points: from the top-right shoulder down the left waist, through the
    /// first notch to the bottom tip, then back up the long right edge and
    /// through the second notch. The tilted hits keep the zigzag tapered — the
    /// upper arm is widest at the top and the lower arm narrows to the tip —
    /// and, with a 1.6 pt stroke, every edge stays inside the canvas.
    static func boltPath() -> CGPath {
        let points = [
            CGPoint(x: 12.0, y: 16.7),  // top-right shoulder
            CGPoint(x: 3.5, y: 7.8),  // left waist
            CGPoint(x: 7.7, y: 7.8),  // first notch
            CGPoint(x: 6.0, y: 1.3),  // bottom tip
            CGPoint(x: 14.5, y: 10.1),  // right waist
            CGPoint(x: 10.5, y: 10.1),  // second notch
        ]
        let path = CGMutablePath()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    /// The menu-bar icon: the bolt filled black with the 1.6 pt stroke, marked
    /// as a template image so macOS recolours it per menu-bar appearance.
    public static func templateImage() -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            drawBolt(in: context, fill: .black, stroke: .black)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The flash variant `StatusItemController` shows for about a second when a
    /// word is learned: the same bolt, outlined instead of filled.
    static func outlinedTemplateImage() -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            drawBolt(in: context, fill: nil, stroke: .black)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Draws the bolt into `context`.
    /// - Parameters:
    ///   - fill: `nil` leaves the bolt hollow (the flash variant).
    ///   - stroke: the outline colour, drawn over the fill when present.
    private static func drawBolt(in context: CGContext, fill: NSColor?, stroke: NSColor?) {
        if let fill {
            context.addPath(boltPath())
            context.setFillColor(fill.cgColor)
            context.fillPath()
        }
        if let stroke {
            // `fillPath` consumes the current path, so re-add it for the stroke.
            context.addPath(boltPath())
            context.setStrokeColor(stroke.cgColor)
            context.setLineWidth(strokeWidth)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.strokePath()
        }
    }
}
