import AppKit

/// The menu-bar mark: the app icon's minimal unit — a single soft 3-D cube —
/// rendered at status-bar size. Selectable in Settings.
enum MenuBarIcon: String, CaseIterable, Identifiable {
    case solid     // three teal faces, crisp edges
    case soft      // three teal faces, gently bowed edges (matches the artwork)
    case outline   // monochrome line-art cube (template — follows the menu-bar appearance)

    var id: String { rawValue }
    var label: String {
        switch self {
        case .solid:   return "Cube"
        case .soft:    return "Cube (soft)"
        case .outline: return "Outline"
        }
    }
    /// Outline is a template so macOS tints/dims it with the menu bar; the colored
    /// cubes render as-is to keep the brand teal.
    var isTemplate: Bool { self == .outline }

    /// A square menu-bar image (~18 pt) of the cube in this style.
    func image(height: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: height, height: height), flipped: false) { rect in
            CubeIcon.draw(in: rect, style: self)
            return true
        }
        img.isTemplate = isTemplate
        img.accessibilityDescription = "Tokenomics"
        return img
    }
}

/// Draws the brand cube. Colors are sampled from the app icon's tessellation
/// (Tailwind sky-300 / cyan-500 / cyan-700).
enum CubeIcon {
    static let light = NSColor(srgbRed: 0x7D/255, green: 0xD3/255, blue: 0xFC/255, alpha: 1)
    static let med   = NSColor(srgbRed: 0x06/255, green: 0xB6/255, blue: 0xD4/255, alpha: 1)
    static let dark  = NSColor(srgbRed: 0x0E/255, green: 0x74/255, blue: 0x90/255, alpha: 1)

    static func draw(in rect: NSRect, style: MenuBarIcon) {
        let R = min(rect.width, rect.height) * 0.42   // leave room for the bow / stroke
        let cx = rect.midX, cy = rect.midY
        let k: CGFloat = 0.8660254
        let T  = CGPoint(x: cx,       y: cy + R)
        let UR = CGPoint(x: cx + k*R, y: cy + 0.5*R)
        let LR = CGPoint(x: cx + k*R, y: cy - 0.5*R)
        let B  = CGPoint(x: cx,       y: cy - R)
        let LL = CGPoint(x: cx - k*R, y: cy - 0.5*R)
        let UL = CGPoint(x: cx - k*R, y: cy + 0.5*R)
        let O  = CGPoint(x: cx,       y: cy)

        if style == .outline {
            let stroke = NSColor.black            // template image — actual tint applied by AppKit
            let w = max(1, R * 0.16)
            let hex = face([T, UR, LR, B, LL, UL], curved: Array(repeating: false, count: 6), center: O, R: R, bow: 0)
            hex.lineWidth = w; hex.lineJoinStyle = .round; stroke.setStroke(); hex.stroke()
            for p in [UR, UL, B] {                // the three visible interior edges
                let spoke = NSBezierPath(); spoke.move(to: O); spoke.line(to: p)
                spoke.lineWidth = w; spoke.lineCapStyle = .round; stroke.setStroke(); spoke.stroke()
            }
            return
        }

        let bow: CGFloat = style == .soft ? 0.14 : 0
        light.setFill(); face([T, UR, O, UL], curved: [true, false, false, true],  center: O, R: R, bow: bow).fill()
        med.setFill();   face([UL, O, B, LL], curved: [false, false, true, true],  center: O, R: R, bow: bow).fill()
        dark.setFill();  face([UR, LR, B, O], curved: [true, true, false, false],  center: O, R: R, bow: bow).fill()
    }

    /// Build one face. Perimeter edges (curved=true) bow radially outward by `bow·R`;
    /// interior spokes stay straight so adjacent faces share an identical edge.
    private static func face(_ pts: [CGPoint], curved: [Bool], center: CGPoint, R: CGFloat, bow: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: pts[0])
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            if bow > 0 && curved[i] {
                let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                var dx = m.x - center.x, dy = m.y - center.y
                let len = max(0.0001, (dx*dx + dy*dy).squareRoot()); dx /= len; dy /= len
                let c = CGPoint(x: m.x + dx*bow*R, y: m.y + dy*bow*R)
                path.curve(to: b,
                           controlPoint1: CGPoint(x: a.x + (c.x - a.x) * 0.66, y: a.y + (c.y - a.y) * 0.66),
                           controlPoint2: CGPoint(x: b.x + (c.x - b.x) * 0.66, y: b.y + (c.y - b.y) * 0.66))
            } else {
                path.line(to: b)
            }
        }
        path.close()
        return path
    }
}
