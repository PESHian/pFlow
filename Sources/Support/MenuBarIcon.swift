import AppKit

/// Monochrome version of PESH/brand/pesh-mark.svg, kept as a native template
/// so the menu bar remains legible in every system appearance.
enum MenuBarIcon {
    static func image(recording: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            context.translateBy(x: 0, y: 20)
            context.scaleBy(x: 20.0 / 64, y: -20.0 / 64)
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineJoin(.round)
            let ears: [[CGPoint]] = [
                [CGPoint(x: 17.5, y: 21.5), CGPoint(x: 11, y: 6.5), CGPoint(x: 27, y: 15.5)],
                [CGPoint(x: 46.5, y: 21.5), CGPoint(x: 53, y: 6.5), CGPoint(x: 37, y: 15.5)]
            ]
            for points in ears {
                context.move(to: points[0]); context.addLines(between: Array(points.dropFirst()))
                context.closePath(); context.fillPath()
            }
            let snout = CGPath(roundedRect: CGRect(x: 10.5, y: 20, width: 43, height: 34),
                               cornerWidth: 17, cornerHeight: 17, transform: nil)
            context.addPath(snout)
            if recording { context.fillPath(); context.setBlendMode(.clear) }
            else { context.setLineWidth(3.5); context.strokePath() }
            for x in [21.4, 35.4] {
                context.fillEllipse(in: CGRect(x: x, y: 30.8, width: 7.2, height: 12.4))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
