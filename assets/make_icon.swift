import AppKit

// E note LOGO — 作者：韦冬 2220285589@qq.com
// 蓝色 E 字母 + 叠层便签。用明确的像素画布确保非 Retina / Retina 输出一致。
// 运行 ./assets/build-icon.sh 生成 PNG 和完整尺寸 ICNS。
let edge = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: edge * 4, bitsPerPixel: 32)!
let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let ctx = graphics.cgContext
ctx.clear(CGRect(x: 0, y: 0, width: edge, height: edge))
ctx.translateBy(x: 0, y: CGFloat(edge))
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func card(_ rect: CGRect, radius: CGFloat, fill: UInt32, shadow: Bool = false) {
    ctx.saveGState()
    if shadow {
        ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 24,
                      color: NSColor.black.withAlphaComponent(0.15).cgColor)
    }
    color(fill).setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    ctx.restoreGState()
}

// macOS 图标留出透明边距，圆角底板与系统应用的视觉尺寸一致。
let tile = NSBezierPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                        xRadius: 184, yRadius: 184)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 22,
              color: NSColor.black.withAlphaComponent(0.18).cgColor)
color(0xEFF3FD).setFill()
tile.fill()
ctx.restoreGState()
NSGradient(starting: color(0xF8FAFF), ending: color(0xE4EBFC))!.draw(in: tile, angle: 90)

// 右上错位的两张索引纸，呼应应用从边缘展开便签的形态。
card(CGRect(x: 352, y: 207, width: 430, height: 556), radius: 54, fill: 0xB8B5F7)
card(CGRect(x: 297, y: 245, width: 447, height: 555), radius: 54, fill: 0x76ADF5)
card(CGRect(x: 242, y: 284, width: 463, height: 546), radius: 54, fill: 0xFFFFFF, shadow: true)

// 单一、粗笔画 E：在 16px 和 32px 图标下仍能识别。
let ink: UInt32 = 0x3267DC
card(CGRect(x: 326, y: 387, width: 76, height: 334), radius: 24, fill: ink)
card(CGRect(x: 326, y: 387, width: 286, height: 76), radius: 24, fill: ink)
card(CGRect(x: 326, y: 516, width: 241, height: 76), radius: 24, fill: ink)
card(CGRect(x: 326, y: 645, width: 286, height: 76), radius: 24, fill: ink)

NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("assets/icon-1024.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print("生成：", output.path)
