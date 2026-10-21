// Renders AppIcon.icns: an SF Symbol drive on a blue rounded square. Usage: swift tools/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let img = NSImage(size: NSSize(width: px, height: px), flipped: false) { r in
        let inset = r.insetBy(dx: r.width * 0.1, dy: r.height * 0.1)
        let path = NSBezierPath(roundedRect: inset, xRadius: inset.width * 0.225, yRadius: inset.width * 0.225)
        NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.98, alpha: 1),
                   ending: NSColor(calibratedRed: 0.08, green: 0.28, blue: 0.75, alpha: 1))!.draw(in: path, angle: -90)
        let cfg = NSImage.SymbolConfiguration(pointSize: inset.width * 0.5, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let s = sym.size
            sym.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
        }
        return true
    }
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
