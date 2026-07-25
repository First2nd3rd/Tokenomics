import AppKit

/// Renders the menu-bar content (optional cube + the two stacked lines) into a
/// single NSImage. NSStatusBarButton reliably centers an IMAGE vertically in the
/// bar at any bar height (notched Macs are ~33pt, not 24) while a multi-line
/// attributedTitle is top-anchored — so all text goes through here.
///
/// Colors resolve at DRAW time inside the image's drawing handler, so
/// `labelColor` follows the menu bar's effective appearance (white over a dark
/// or tinted bar, black over a light one) just like the button title did.
enum StatusImage {
    private static let lineHeight: CGFloat = 10
    private static let iconSide: CGFloat = 18
    private static let iconGap: CGFloat = 3

    static func make(_ lines: StatusLine.Lines, icon: MenuBarIcon) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let rows = lines.bottom.isEmpty ? [lines.top] : [lines.top, lines.bottom]
        let textWidth = rows.map { ceil(size($0, font).width) }.max() ?? 0
        let iconWidth = icon == .hidden ? 0 : iconSide + iconGap
        let width = max(iconWidth + textWidth, 8)
        let height = max(iconSide, lineHeight * CGFloat(rows.count)) + 2

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            if icon != .hidden {
                let iconRect = NSRect(x: 0, y: (rect.height - iconSide) / 2,
                                      width: iconSide, height: iconSide)
                CubeIcon.draw(in: iconRect, style: icon)
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
            let blockHeight = lineHeight * CGFloat(rows.count)
            var y = (rect.height + blockHeight) / 2 - lineHeight
            for row in rows {
                let s = size(row, font)
                let x = rect.width - s.width      // right-aligned column of digits
                row.draw(at: NSPoint(x: x, y: y + (lineHeight - s.height) / 2),
                         withAttributes: attrs)
                y -= lineHeight
            }
            return true
        }
        image.accessibilityDescription = "Tokenomics: \(lines.top) \(lines.bottom)"
        return image
    }

    private static func size(_ text: String, _ font: NSFont) -> NSSize {
        (text as NSString).size(withAttributes: [.font: font])
    }
}
