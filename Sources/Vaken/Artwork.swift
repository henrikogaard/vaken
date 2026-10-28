import AppKit

enum VakenArtwork {
    static let ink = NSColor(srgbRed: 0.07, green: 0.10, blue: 0.14, alpha: 1)
    static let gold = NSColor(srgbRed: 1, green: 0.72, blue: 0.32, alpha: 1)
    static let ivory = NSColor(srgbRed: 0.96, green: 0.94, blue: 0.88, alpha: 1)

    // Approved outline sun/crescent geometry, in a 100-unit coordinate square.
    static func mark(in rect: NSRect, color: NSColor, active: Bool) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / 100, yBy: rect.height / 100)
        transform.concat()
        color.set()
        let path = NSBezierPath()
        if active {
            path.appendOval(in: NSRect(x: 32, y: 32, width: 36, height: 36))
            for ray in 0..<8 {
                let angle = CGFloat(ray) * .pi / 4
                path.move(to: .init(x: 50 + cos(angle) * 28, y: 50 + sin(angle) * 28))
                path.line(to: .init(x: 50 + cos(angle) * 37, y: 50 + sin(angle) * 37))
            }
            path.lineWidth = 6.5
            path.lineCapStyle = .round
            path.stroke()
        } else {
            let distance = sqrt(14.0 * 14 + 11 * 11)
            let h = sqrt(30.0 * 30 - distance * distance / 4)
            let top = NSPoint(x: 57 - 11 / distance * h, y: 55.5 + 14 / distance * h)
            let bottom = NSPoint(x: 57 + 11 / distance * h, y: 55.5 - 14 / distance * h)
            func angle(_ point: NSPoint, _ center: NSPoint) -> CGFloat {
                atan2(point.y - center.y, point.x - center.x) * 180 / .pi
            }
            let outer = NSPoint(x: 50, y: 50), inner = NSPoint(x: 64, y: 61)
            path.appendArc(withCenter: outer, radius: 30, startAngle: angle(top, outer), endAngle: angle(bottom, outer), clockwise: false)
            path.appendArc(withCenter: inner, radius: 30, startAngle: angle(bottom, inner), endAngle: angle(top, inner), clockwise: true)
            path.close()
            path.fill()
        }
    }

    static func appIcon(size: CGFloat, active: Bool = true) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.insetBy(dx: size * 0.055, dy: size * 0.055)
            ink.setFill()
            NSBezierPath(roundedRect: inset, xRadius: size * 0.2, yRadius: size * 0.2).fill()
            mark(in: rect.insetBy(dx: size * 0.13, dy: size * 0.13), color: active ? gold : ivory, active: active)
            return true
        }
    }

    static func menuIcon(active: Bool, error: Bool) -> NSImage {
        if error {
            let image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "Vaken needs attention")!
            image.isTemplate = true
            return image
        }
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            mark(in: rect, color: .black, active: active)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func png(_ image: NSImage, pixels: Int, to url: URL) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    static func export(to path: String) throws {
        let root = URL(fileURLWithPath: path)
        let iconset = root.appendingPathComponent("Vaken.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for factor in [1, 2] {
                let name = "icon_\(size)x\(size)\(factor == 2 ? "@2x" : "").png"
                try png(appIcon(size: CGFloat(size * factor)), pixels: size * factor, to: iconset.appendingPathComponent(name))
            }
        }
        try png(appIcon(size: 1024), pixels: 1024, to: root.appendingPathComponent("Vaken.png"))
        try png(appIcon(size: 1024, active: false), pixels: 1024, to: root.appendingPathComponent("Vaken-moon.png"))
        for active in [true, false] {
            for pixels in [22, 44] {
                try png(menuIcon(active: active, error: false), pixels: pixels,
                        to: root.appendingPathComponent("menu-\(active ? "on" : "off")-\(pixels).png"))
            }
        }
    }
}
