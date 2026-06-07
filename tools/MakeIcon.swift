#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Renders the Return Visits app icon: a warm green gradient with a white map pin whose
// face carries three "note" lines — a noted place. Run: swift tools/MakeIcon.swift <outdir>

let size = 1024
let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Sources/Assets.xcassets/AppIcon.appiconset"

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("Could not create context") }

let w = CGFloat(size), h = CGFloat(size)

func drawBackground() {
    let top = CGColor(red: 0.16, green: 0.60, blue: 0.52, alpha: 1)     // bright sage
    let bottom = CGColor(red: 0.07, green: 0.40, blue: 0.35, alpha: 1)  // deep teal-green
    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: [top, bottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: h),
                           end: CGPoint(x: 0, y: 0),
                           options: [])
}

// The pin: a teardrop pointing down, centered horizontally.
let center = CGPoint(x: w / 2, y: h * 0.60)   // head center
let radius: CGFloat = w * 0.225
let point = CGPoint(x: w / 2, y: h * 0.16)     // bottom tip

func pinPath() -> CGPath {
    let p = CGMutablePath()
    let a0 = -50.0 * .pi / 180.0
    let a1 = 230.0 * .pi / 180.0
    let rightTangent = CGPoint(x: center.x + radius * CGFloat(cos(a0)),
                               y: center.y + radius * CGFloat(sin(a0)))
    p.move(to: point)
    p.addLine(to: rightTangent)
    p.addArc(center: center, radius: radius,
             startAngle: CGFloat(a0), endAngle: CGFloat(a1), clockwise: false)
    p.closeSubpath()
    return p
}

func drawPin() {
    // Soft shadow under the pin.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18),
                  blur: 36,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.addPath(pinPath())
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
}

func drawNoteLines() {
    let noteColor = CGColor(red: 0.09, green: 0.42, blue: 0.37, alpha: 1)
    ctx.setFillColor(noteColor)
    let lineHeight: CGFloat = radius * 0.16
    let spacing: CGFloat = radius * 0.42
    let widths: [CGFloat] = [radius * 1.05, radius * 1.05, radius * 0.7]
    for (i, lw) in widths.enumerated() {
        let y = center.y + spacing - CGFloat(i) * spacing - lineHeight / 2
        let x = center.x - lw / 2
        let rect = CGRect(x: x, y: y, width: lw, height: lineHeight)
        let rounded = CGPath(roundedRect: rect,
                             cornerWidth: lineHeight / 2,
                             cornerHeight: lineHeight / 2,
                             transform: nil)
        ctx.addPath(rounded)
        ctx.fillPath()
    }
}

drawBackground()
drawPin()
drawNoteLines()

guard let image = ctx.makeImage() else { fatalError("Could not render image") }
let url = URL(fileURLWithPath: outDir).appendingPathComponent("icon-1024.png")
guard let dest = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil
) else { fatalError("Could not create destination") }
CGImageDestinationAddImage(dest, image, nil)
if CGImageDestinationFinalize(dest) {
    print("Wrote \(url.path)")
} else {
    fatalError("Could not write PNG")
}
