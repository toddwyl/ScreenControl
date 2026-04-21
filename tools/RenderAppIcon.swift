#!/usr/bin/env swift
import AppKit
import CoreGraphics

// 生成 KeepAgentAwake 应用图标：显示器轮廓 + 月亮/光线，深色圆角背景

let size: CGFloat = 1024
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon_1024.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("无法创建位图\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fputs("无法获取上下文\n", stderr)
    exit(1)
}

let rect = CGRect(x: 0, y: 0, width: size, height: size)
let corner: CGFloat = size * 0.2237 // ~229 for 1024

// 背景渐变
let bgColors = [
    NSColor(red: 0.12, green: 0.14, blue: 0.22, alpha: 1).cgColor,
    NSColor(red: 0.05, green: 0.07, blue: 0.12, alpha: 1).cgColor,
]
let bgGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors as CFArray, locations: [0, 1])!
let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
ctx.addPath(path)
ctx.clip()
ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

ctx.resetClip()
ctx.addPath(path)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
ctx.setLineWidth(size * 0.012)
ctx.strokePath()

// 显示器外框
let margin = size * 0.18
let screenRect = CGRect(x: margin, y: margin * 1.15, width: size - margin * 2, height: size * 0.48)
let screenPath = CGPath(roundedRect: screenRect, cornerWidth: size * 0.035, cornerHeight: size * 0.035, transform: nil)
ctx.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
ctx.addPath(screenPath)
ctx.fillPath()
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
ctx.setLineWidth(size * 0.014)
ctx.addPath(screenPath)
ctx.strokePath()

// 屏幕内高光（模拟“亮屏”）
let inner = screenRect.insetBy(dx: size * 0.04, dy: size * 0.04)
let glow = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 0.55).cgColor,
        NSColor(red: 0.1, green: 0.35, blue: 0.65, alpha: 0.15).cgColor,
    ] as CFArray,
    locations: [0, 1]
)!
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: inner, cornerWidth: size * 0.02, cornerHeight: size * 0.02, transform: nil))
ctx.clip()
ctx.drawLinearGradient(glow, start: CGPoint(x: inner.minX, y: inner.maxY), end: CGPoint(x: inner.maxX, y: inner.minY), options: [])
ctx.restoreGState()

// 底座
let standW = size * 0.22
let standH = size * 0.06
let stand = CGRect(
    x: (size - standW) / 2,
    y: margin * 0.55,
    width: standW,
    height: standH
)
let standPath = CGPath(roundedRect: stand, cornerWidth: standH / 2, cornerHeight: standH / 2, transform: nil)
ctx.setFillColor(NSColor.white.withAlphaComponent(0.15).cgColor)
ctx.addPath(standPath)
ctx.fillPath()

// 月亮（熄屏意象）
let moonCenter = CGPoint(x: size * 0.72, y: size * 0.72)
let moonR = size * 0.11
ctx.setFillColor(NSColor(red: 1, green: 0.92, blue: 0.65, alpha: 1).cgColor)
ctx.addEllipse(in: CGRect(x: moonCenter.x - moonR, y: moonCenter.y - moonR, width: moonR * 2, height: moonR * 2))
ctx.fillPath()
ctx.setBlendMode(.clear)
ctx.addEllipse(in: CGRect(x: moonCenter.x - moonR * 0.45, y: moonCenter.y - moonR * 0.1, width: moonR * 1.9, height: moonR * 1.7))
ctx.fillPath()
ctx.setBlendMode(.normal)

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    fputs("无法编码 PNG\n", stderr)
    exit(1)
}
try data.write(to: URL(fileURLWithPath: outputPath))
print(" wrote \(outputPath)")
