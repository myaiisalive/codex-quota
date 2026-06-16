#!/usr/bin/env swift
// 生成 AppIcon.icns（不需要外部图片，纯代码绘制）
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = "\(outDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func render(size: Int) -> NSImage {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }

    // 圆角背景：紫蓝渐变
    let radius = s * 0.225
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()

    let colors = [
        NSColor(red: 0.32, green: 0.31, blue: 0.95, alpha: 1).cgColor,
        NSColor(red: 0.13, green: 0.10, blue: 0.55, alpha: 1).cgColor,
    ] as CFArray
    let grad = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: s), options: [])

    // 仪表盘弧
    let cx = s / 2, cy = s * 0.56
    let r = s * 0.32
    let lineW = s * 0.07
    ctx.setLineCap(.round)
    ctx.setLineWidth(lineW)

    // 背景弧（白色淡）
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r,
               startAngle: .pi * 1.15, endAngle: -.pi * 0.15, clockwise: false)
    ctx.strokePath()

    // 前景弧（白色，约 70%）
    ctx.setStrokeColor(NSColor.white.cgColor)
    let total = (-.pi * 0.15) - (.pi * 1.15) + .pi * 2
    let end = .pi * 1.15 + total * 0.7
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r,
               startAngle: .pi * 1.15, endAngle: end, clockwise: false)
    ctx.strokePath()

    // 指针
    let needleAngle = end
    let nx = cx + cos(needleAngle) * r * 0.85
    let ny = cy + sin(needleAngle) * r * 0.85
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(lineW * 0.55)
    ctx.move(to: CGPoint(x: cx, y: cy))
    ctx.addLine(to: CGPoint(x: nx, y: ny))
    ctx.strokePath()

    // 中心圆点
    ctx.setFillColor(NSColor.white.cgColor)
    let dot = s * 0.05
    ctx.fillEllipse(in: CGRect(x: cx - dot, y: cy - dot, width: dot * 2, height: dot * 2))

    img.unlockFocus()
    return img
}

func savePNG(_ img: NSImage, to path: String) {
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

let sizes: [(Int, String)] = [
    (16,  "icon_16x16.png"),
    (32,  "icon_16x16@2x.png"),
    (32,  "icon_32x32.png"),
    (64,  "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024,"icon_512x512@2x.png"),
]
for (px, name) in sizes {
    savePNG(render(size: px), to: "\(iconset)/\(name)")
}
print("生成 \(iconset)")
