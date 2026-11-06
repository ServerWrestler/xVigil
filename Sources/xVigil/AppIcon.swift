import AppKit

/// The app icon, drawn entirely from original vector geometry: a white
/// shield with a watchful eye on a deep-blue rounded rectangle. No Apple
/// artwork (SF Symbols are licensed for UI glyphs, not app icons or logos).
/// One source of truth: the running app sets it as the Dock icon, and
/// make-app.sh asks the binary to dump it as a PNG (XVIGIL_DUMP_ICON) to
/// build the bundle's .icns from the same drawing.
enum AppIcon {
    static func image(size: CGFloat = 1024) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        drawBackground(size: size)
        drawShield(size: size)
        drawEye(size: size)
        return image
    }

    // MARK: - Palette

    private static let skyBlue = NSColor(calibratedRed: 0.13, green: 0.36, blue: 0.62, alpha: 1)
    private static let navy = NSColor(calibratedRed: 0.04, green: 0.14, blue: 0.30, alpha: 1)
    private static let eyeBlue = NSColor(calibratedRed: 0.09, green: 0.27, blue: 0.52, alpha: 1)

    // MARK: - Layers

    /// macOS-style icon: rounded rect inset from the canvas edge.
    private static func drawBackground(size: CGFloat) {
        let inset = size * 0.08
        let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.185, yRadius: size * 0.185)
        NSGradient(starting: skyBlue, ending: navy)?.draw(in: path, angle: -90)
    }

    /// Heraldic shield: rounded top corners, straight sides, curving to a
    /// point. Soft shadow lifts it off the background.
    private static func drawShield(size: CGFloat) {
        let cx = size / 2
        let halfWidth = size * 0.255
        let top = size * 0.775
        let bottom = size * 0.185
        let height = top - bottom
        let shoulder = top - height * 0.36  // where the sides start to curve
        let corner = size * 0.055

        let path = NSBezierPath()
        path.move(to: NSPoint(x: cx - halfWidth + corner, y: top))
        path.line(to: NSPoint(x: cx + halfWidth - corner, y: top))
        path.curve(
            to: NSPoint(x: cx + halfWidth, y: top - corner),
            controlPoint1: NSPoint(x: cx + halfWidth - corner * 0.45, y: top),
            controlPoint2: NSPoint(x: cx + halfWidth, y: top - corner * 0.45))
        path.line(to: NSPoint(x: cx + halfWidth, y: shoulder))
        path.curve(
            to: NSPoint(x: cx, y: bottom),
            controlPoint1: NSPoint(x: cx + halfWidth, y: shoulder - height * 0.30),
            controlPoint2: NSPoint(x: cx + halfWidth * 0.42, y: bottom + height * 0.16))
        path.curve(
            to: NSPoint(x: cx - halfWidth, y: shoulder),
            controlPoint1: NSPoint(x: cx - halfWidth * 0.42, y: bottom + height * 0.16),
            controlPoint2: NSPoint(x: cx - halfWidth, y: shoulder - height * 0.30))
        path.line(to: NSPoint(x: cx - halfWidth, y: top - corner))
        path.curve(
            to: NSPoint(x: cx - halfWidth + corner, y: top),
            controlPoint1: NSPoint(x: cx - halfWidth, y: top - corner * 0.45),
            controlPoint2: NSPoint(x: cx - halfWidth + corner * 0.45, y: top))
        path.close()

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = size * 0.03
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.014)
        shadow.set()
        NSGradient(
            starting: NSColor(calibratedWhite: 0.90, alpha: 1),
            ending: NSColor.white)?.draw(in: path, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// An almond-shaped eye with an iris and pupil, centered on the shield.
    private static func drawEye(size: CGFloat) {
        let cx = size / 2
        let cy = size * 0.545
        let halfWidth = size * 0.155
        let lift = size * 0.115  // control-point height of the lids

        let eye = NSBezierPath()
        eye.move(to: NSPoint(x: cx - halfWidth, y: cy))
        eye.curve(
            to: NSPoint(x: cx + halfWidth, y: cy),
            controlPoint1: NSPoint(x: cx - halfWidth * 0.45, y: cy + lift),
            controlPoint2: NSPoint(x: cx + halfWidth * 0.45, y: cy + lift))
        eye.curve(
            to: NSPoint(x: cx - halfWidth, y: cy),
            controlPoint1: NSPoint(x: cx + halfWidth * 0.45, y: cy - lift),
            controlPoint2: NSPoint(x: cx - halfWidth * 0.45, y: cy - lift))
        eye.close()
        eyeBlue.setFill()
        eye.fill()

        func disc(radius: CGFloat, color: NSColor) {
            let rect = NSRect(
                x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
        disc(radius: size * 0.062, color: .white)
        disc(radius: size * 0.030, color: navy)
    }

    /// Build-time hook for make-app.sh.
    static func writePNG(to path: String) {
        guard let tiff = image().tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
