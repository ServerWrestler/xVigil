import AppKit

/// The app icon, drawn programmatically: a white shield on a deep-blue
/// rounded rectangle. One source of truth — the running app sets it as the
/// Dock icon, and make-app.sh asks the binary to dump it as a PNG
/// (XVIGIL_DUMP_ICON) to build the bundle's .icns from the same drawing.
enum AppIcon {
    static func image(size: CGFloat = 1024) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        // macOS-style icon: rounded rect inset from the canvas edge.
        let inset = size * 0.08
        let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        let background = NSBezierPath(
            roundedRect: rect, xRadius: size * 0.185, yRadius: size * 0.185)
        NSGradient(
            starting: NSColor(calibratedRed: 0.13, green: 0.36, blue: 0.62, alpha: 1),
            ending: NSColor(calibratedRed: 0.04, green: 0.14, blue: 0.30, alpha: 1)
        )?.draw(in: background, angle: -90)

        if let shield = tintedShield(fitting: size * 0.52) {
            let origin = NSPoint(
                x: (size - shield.size.width) / 2,
                y: (size - shield.size.height) / 2)
            shield.draw(in: NSRect(origin: origin, size: shield.size))
        }
        return image
    }

    /// SF Symbol shield rendered white. Symbols draw as black templates in
    /// direct drawing contexts, so tint via a sourceAtop fill.
    private static func tintedShield(fitting target: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: target, weight: .medium)
        guard let symbol = NSImage(
            systemSymbolName: "shield.lefthalf.filled",
            accessibilityDescription: "xVigil")?
            .withSymbolConfiguration(config)
        else { return nil }

        let scale = target / max(symbol.size.width, symbol.size.height)
        let drawSize = NSSize(
            width: symbol.size.width * scale, height: symbol.size.height * scale)

        let tinted = NSImage(size: drawSize)
        tinted.lockFocus()
        let bounds = NSRect(origin: .zero, size: drawSize)
        symbol.draw(in: bounds)
        NSColor.white.set()
        bounds.fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
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
