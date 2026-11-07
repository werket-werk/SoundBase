// Usage: swift scripts/make-mac-icon.swift <square-icon.png> <out-1024.png>
// Draws the square iOS artwork as a macOS-style rounded square with standard padding and shadow.
import AppKit
let src = NSImage(contentsOfFile: CommandLine.arguments[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let size = 1024, inset = 100.0, s = Double(size)
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rect = CGRect(x: inset, y: inset + 12, width: s - inset * 2, height: s - inset * 2)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(path); ctx.clip()
ctx.draw(src, in: rect)
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
