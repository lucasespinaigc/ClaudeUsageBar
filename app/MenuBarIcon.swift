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
private func sparkPath() -> NSBezierPath {
    let raw: [(CGFloat, CGFloat)] = [
        (8, 1), (9, 6), (13, 3), (10, 7), (15, 8), (10, 9), (13, 13), (9, 10),
        (8, 15), (7, 10), (3, 13), (6, 9), (1, 8), (6, 7), (3, 3), (7, 6)
    ]
    let path = NSBezierPath()
    for (index, point) in raw.enumerated() {
        let p = NSPoint(x: point.0, y: point.1)
        if index == 0 { path.move(to: p) } else { path.line(to: p) }
    }
    path.close()
    return path
}

func menuBarIcon(percentage: Int) -> NSImage {
    let color = usageColor(percentage: percentage)
    let image = NSImage(size: NSSize(width: 16, height: 16))
    image.lockFocus()
    color.setFill()
    sparkPath().fill()
    image.unlockFocus()
    image.isTemplate = false
    return image
}
