import AppKit
import Foundation

/// The menu bar glyph: the ghost bell from the app icon, drawn rather than shipped.
///
/// Drawn in code on purpose. A vector the app renders itself is one file
/// instead of an asset catalogue, scales to whatever height the menu bar is,
/// and — being a template image — inverts with the menu bar's appearance
/// without a second copy for dark mode. It is the same ghost as the
/// notification's icon, so the item in the bar and the banners it lists read
/// as one app.
enum GhostMark {
    /// Breathing room inside the square the menu bar gives us. The ghost is
    /// nearly as wide as it is tall, so it fills the square almost edge to edge.
    private static let inset: CGFloat = 0.04

    /// `crossedOut` is the "nothing will ever appear" state — the mark with a
    /// slash through it, the way macOS strikes through a disabled bell.
    static func image(height: CGFloat = 18, crossedOut: Bool) -> NSImage {
        let size = NSSize(width: height, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let stroke = max(1.3, rect.width * 0.09)

            NSColor.black.setFill()
            ghost(in: rect.insetBy(dx: rect.width * inset, dy: rect.height * inset)).fill()

            guard crossedOut else { return true }

            // Carve a gap first, then draw the slash into it. Without the gap the
            // slash disappears into the body — a template image has no second
            // colour to fall back on.
            let reach = rect.width * 0.5
            let from = CGPoint(x: center.x - reach * 0.72, y: center.y - reach * 0.72)
            let to = CGPoint(x: center.x + reach * 0.72, y: center.y + reach * 0.72)

            NSGraphicsContext.current?.compositingOperation = .destinationOut
            let gap = NSBezierPath()
            // Just enough daylight to read as a break. Wider and the slash cuts
            // the ghost in two, and the crossed-out state stops looking like the
            // same mark.
            gap.lineWidth = stroke * 1.8
            gap.lineCapStyle = .round
            gap.move(to: from)
            gap.line(to: to)
            gap.stroke()

            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setStroke()
            let slash = NSBezierPath()
            slash.lineWidth = stroke
            slash.lineCapStyle = .round
            slash.move(to: from)
            slash.line(to: to)
            slash.stroke()
            return true
        }
        // Template, so the mark follows the menu bar's light/dark appearance
        // instead of fighting it — and stays legible over a translucent bar.
        image.isTemplate = true
        return image
    }

    /// The ghost bell in `r`: body, two eyes and the clapper.
    ///
    /// Traced from the 1024 px icon master (agent/Resources/AppIcon.png) with
    /// potrace at opttolerance 0.6 — 26 segments matching the artwork to an
    /// intersection over union of 0.996 — then scaled to a unit square with y
    /// up and the shape centred. One liberty: the clapper sits 14 px (of the
    /// master) lower than in the artwork. At the artwork's own spacing the gap
    /// above it is under a pixel on a 1x display, and the clapper runs into the
    /// skirt. Even-odd, so the eyes are holes: a template image has no white to
    /// paint them with.
    private static func ghost(in r: NSRect) -> NSBezierPath {
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: r.minX + x * r.width, y: r.minY + y * r.height)
        }
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        // Body
        path.move(to: p(0.524, 0.999))
        path.curve(
            to: p(0.263, 0.847), controlPoint1: p(0.417, 0.990),
            controlPoint2: p(0.322, 0.935))
        path.curve(
            to: p(0.201, 0.685), controlPoint1: p(0.235, 0.805),
            controlPoint2: p(0.219, 0.764))
        path.curve(
            to: p(0.047, 0.371), controlPoint1: p(0.160, 0.507),
            controlPoint2: p(0.123, 0.430))
        path.curve(
            to: p(0.015, 0.336), controlPoint1: p(0.030, 0.357),
            controlPoint2: p(0.018, 0.344))
        path.curve(
            to: p(0.062, 0.252), controlPoint1: p(0.004, 0.306),
            controlPoint2: p(0.023, 0.271))
        path.curve(
            to: p(0.185, 0.246), controlPoint1: p(0.096, 0.235),
            controlPoint2: p(0.129, 0.233))
        path.curve(
            to: p(0.337, 0.220), controlPoint1: p(0.250, 0.261),
            controlPoint2: p(0.276, 0.256))
        path.curve(
            to: p(0.628, 0.178), controlPoint1: p(0.437, 0.160),
            controlPoint2: p(0.512, 0.149))
        path.curve(
            to: p(0.806, 0.152), controlPoint1: p(0.707, 0.197),
            controlPoint2: p(0.732, 0.193))
        path.curve(
            to: p(0.954, 0.143), controlPoint1: p(0.861, 0.121),
            controlPoint2: p(0.911, 0.118))
        path.curve(
            to: p(0.971, 0.232), controlPoint1: p(0.992, 0.166),
            controlPoint2: p(0.999, 0.199))
        path.curve(
            to: p(0.886, 0.583), controlPoint1: p(0.895, 0.323),
            controlPoint2: p(0.873, 0.414))
        path.curve(
            to: p(0.858, 0.800), controlPoint1: p(0.893, 0.679),
            controlPoint2: p(0.886, 0.737))
        path.curve(
            to: p(0.524, 0.999), controlPoint1: p(0.799, 0.932),
            controlPoint2: p(0.667, 1.010))
        path.close()
        // Left eye
        path.move(to: p(0.452, 0.731))
        path.curve(
            to: p(0.412, 0.548), controlPoint1: p(0.516, 0.700),
            controlPoint2: p(0.483, 0.548))
        path.curve(
            to: p(0.361, 0.626), controlPoint1: p(0.380, 0.548),
            controlPoint2: p(0.361, 0.577))
        path.curve(
            to: p(0.452, 0.731), controlPoint1: p(0.361, 0.697),
            controlPoint2: p(0.409, 0.752))
        path.close()
        // Right eye
        path.move(to: p(0.688, 0.688))
        path.curve(
            to: p(0.685, 0.524), controlPoint1: p(0.733, 0.666),
            controlPoint2: p(0.732, 0.567))
        path.curve(
            to: p(0.595, 0.583), controlPoint1: p(0.643, 0.485),
            controlPoint2: p(0.596, 0.516))
        path.curve(
            to: p(0.688, 0.688), controlPoint1: p(0.595, 0.653),
            controlPoint2: p(0.644, 0.709))
        path.close()
        // Clapper
        path.move(to: p(0.371, 0.128))
        path.curve(
            to: p(0.372, 0.033), controlPoint1: p(0.351, 0.106),
            controlPoint2: p(0.351, 0.062))
        path.curve(
            to: p(0.517, 0.082), controlPoint1: p(0.417, -0.030),
            controlPoint2: p(0.517, 0.003))
        path.curve(
            to: p(0.505, 0.111), controlPoint1: p(0.517, 0.104),
            controlPoint2: p(0.515, 0.110))
        path.curve(
            to: p(0.470, 0.116), controlPoint1: p(0.501, 0.111),
            controlPoint2: p(0.485, 0.114))
        path.curve(
            to: p(0.375, 0.131), controlPoint1: p(0.435, 0.122),
            controlPoint2: p(0.375, 0.131))
        path.curve(
            to: p(0.371, 0.128), controlPoint1: p(0.374, 0.131),
            controlPoint2: p(0.373, 0.130))
        path.close()
        return path
    }
}
