import AppKit
import SwiftUI

// 作者：韦冬 2220285589@qq.com
// TODOList 专属松柏绿；深色模式使用更明亮的薄荷绿强调色。
enum TodoTheme {
    static let accent = adaptive(light: 0x386D63, dark: 0x95CEB9)
    static let canvas = adaptive(light: 0xEEF4F0, dark: 0x202A26)
    static let surface = adaptive(light: 0xFAFCFA, dark: 0x2A3630)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}
