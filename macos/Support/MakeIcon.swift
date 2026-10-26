// 用 AppKit 画应用图标并输出 .iconset（build.sh 再用 iconutil 转成 .icns）。
// 设计：深色渐变底 + 三条「画像层」横条，其中一条错位并用琥珀色点标出——这就是「跨层找矛盾」。
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return img }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS 图标安全区：画在 1024 栅格里的 100..924 区域，圆角约 22.5%
    let inset = size * 0.098
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 阴影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.20, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // 背景渐变
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        NSColor(calibratedRed: 0.11, green: 0.42, blue: 0.62, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.34, alpha: 1).cgColor,
    ] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // 顶部高光
    let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.midY), options: [])

    // 三条层横条
    let barH = rect.height * 0.11
    let barW = rect.width * 0.54
    let gap = rect.height * 0.075
    let totalH = barH * 3 + gap * 2
    let startY = rect.midY + totalH / 2 - barH
    let baseX = rect.midX - barW / 2
    let offsets: [CGFloat] = [0, rect.width * 0.11, 0] // 中间那条错位
    let alphas: [CGFloat] = [0.95, 0.95, 0.95]
    for i in 0..<3 {
        let y = startY - CGFloat(i) * (barH + gap)
        let r = CGRect(x: baseX + offsets[i], y: y, width: barW, height: barH)
        let p = CGPath(roundedRect: r, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil)
        ctx.addPath(p)
        ctx.setFillColor(NSColor.white.withAlphaComponent(alphas[i]).cgColor)
        ctx.fillPath()
    }
    // 左侧对齐参考线（细）
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
    ctx.setLineWidth(max(1, size * 0.012))
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: baseX - rect.width * 0.07, y: startY + barH + gap * 0.6))
    ctx.addLine(to: CGPoint(x: baseX - rect.width * 0.07, y: startY - 2 * (barH + gap) - gap * 0.6))
    ctx.strokePath()

    // 错位条右端的琥珀色标记
    let midY = startY - (barH + gap) + barH / 2
    let dotR = barH * 0.62
    let dotC = CGPoint(x: baseX + offsets[1] + barW + dotR * 1.1, y: midY)
    ctx.setShadow(offset: .zero, blur: size * 0.03, color: NSColor(calibratedRed: 1, green: 0.62, blue: 0.1, alpha: 0.8).cgColor)
    ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.68, blue: 0.16, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: dotC.x - dotR, y: dotC.y - dotR, width: dotR * 2, height: dotR * 2))
    ctx.restoreGState()

    img.unlockFocus()
    return img
}

func write(_ image: NSImage, px: Int, name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}

for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = pt * scale
    let image = draw(size: CGFloat(px))
    write(image, px: px, name: scale == 1 ? "icon_\(pt)x\(pt)" : "icon_\(pt)x\(pt)@2x")
}
print("iconset written to \(outDir)")
