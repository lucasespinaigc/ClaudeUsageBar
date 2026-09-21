import AppKit

/// Menu bar icon colours. Thresholds match the popover's progress bars
/// (see `colorForPercentage` in UsageView) so a glance at the menu bar and a
/// look at the popover never disagree.
func usageColor(percentage: Int) -> NSColor {
    if percentage < 70 {
        return NSColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1.0) // Green
    } else if percentage < 90 {
        return NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)    // Yellow
    } else {
        return NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)  // Red
    }
}

/// SVG path: M8 1L9 6L13 3L10 7L15 8L10 9L13 13L9 10L8 15L7 10L3 13L6 9L1 8L6 7L3 3L7 6L8 1Z
/// `scale` and `offsetY` shrink the spark up into the top-left corner so a
/// badge digit has a clear bottom-right corner to sit in.
private func sparkPath(scale: CGFloat = 1, offsetY: CGFloat = 0) -> NSBezierPath {
    let raw: [(CGFloat, CGFloat)] = [
        (8, 1), (9, 6), (13, 3), (10, 7), (15, 8), (10, 9), (13, 13), (9, 10),
        (8, 15), (7, 10), (3, 13), (6, 9), (1, 8), (6, 7), (3, 3), (7, 6)
    ]
    let path = NSBezierPath()
    for (index, point) in raw.enumerated() {
        let p = NSPoint(x: point.0 * scale, y: point.1 * scale + offsetY)
        if index == 0 { path.move(to: p) } else { path.line(to: p) }
    }
    path.close()
    return path
}

func menuBarIcon(percentage: Int, badge: Int?) -> NSImage {
    let color = usageColor(percentage: percentage)

    // drawingHandler re-renders at whatever backing scale the icon is drawn at.
    // lockFocus froze one raster at the scale in effect when the image was
    // built, so plugging in a display of a different scale left it resampled —
    // unnoticeable on a flat spark, ugly on a 9pt digit.
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        color.setFill()
        guard let badge = badge else {
            // One account: the 1.3.x icon, untouched. Same path, same size, no
            // badge — a single user must not be able to tell this task shipped.
            sparkPath().fill()
            return true
        }

        // Shrunk and pinned back to the spark's own top edge (y = 15 in path
        // space), which frees the bottom-right corner. 0.8 was not enough: the
        // lower-right arm reached x = 10.4 and touched the "2", and two shapes
        // in one colour that touch read as one blob.
        let sparkScale: CGFloat = 0.7
        sparkPath(scale: sparkScale, offsetY: 15 * (1 - sparkScale)).fill()

        let font = NSFont.systemFont(ofSize: 9, weight: .bold)
        let text = "\(badge)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let size = text.size(withAttributes: attributes)
        // draw(at:) takes the bottom of the line box, which sits one descender
        // below the baseline. Without subtracting it the digit floats ~2pt up,
        // into the spark's lower-right arm, and leaves the corner it was meant
        // to occupy empty. A whole-point baseline keeps the stem edges on pixel
        // boundaries at 1x and 2x alike.
        let baseline: CGFloat = 1
        text.draw(at: NSPoint(x: rect.maxX - size.width,
                              y: rect.minY + baseline + font.descender),
                  withAttributes: attributes)
        return true
    }
    image.isTemplate = false
    return image
}
