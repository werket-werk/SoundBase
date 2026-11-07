// Usage: swift scripts/make-icon.swift <topHex> <bottomHex> <out.png>
import AppKit
func color(_ hex: String) -> CGColor {
    let v = UInt32(hex, radix: 16)!
    return CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}
let args = CommandLine.arguments
let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [color(args[1]), color(args[2])] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
let heights: [Double] = [0.22, 0.42, 0.62, 0.36, 0.52, 0.28]
let barW = 74.0, gap = 44.0, s = Double(size)
var x = (s - (Double(heights.count) * barW + Double(heights.count - 1) * gap)) / 2
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
for h in heights {
    let bh = h * s
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: (s - bh) / 2, width: barW, height: bh), cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    ctx.fillPath()
    x += barW + gap
}
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
