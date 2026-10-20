import AppKit
import SwiftUI

// 作者：韦冬 2220285589@qq.com
// 待办清单配色：石墨中性底 + 靛紫渐变强调色；深色模式提亮强调色保证对比度。
enum TodoTheme {
    static let accent = adaptive(light: 0x5B5BD6, dark: 0xA5A8F8)
    static let accentAlt = adaptive(light: 0x8B5CF6, dark: 0xC9A8FF)
    static let accentCool = adaptive(light: 0x0EA5E9, dark: 0x7DD3FC)
    static let gradient = LinearGradient(colors: [accent, accentAlt], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let ringGradient = AngularGradient(colors: [accentCool, accent, accentAlt, accentCool], center: .center)

    /// 不透明底色，用于无法使用材质的场景（如离屏预览）。
    static let canvas = adaptive(light: 0xF4F4F8, dark: 0x16171D)
    /// 叠在毛玻璃上的色层，透明度较高，只透出少量桌面。
    static let canvasTint = adaptive(light: 0xF6F6FA, dark: 0x14151A, alpha: (0.78, 0.82))
    static let surface = adaptive(light: 0xFFFFFF, dark: 0xFFFFFF, alpha: (0.78, 0.055))
    static let raised = adaptive(light: 0xFFFFFF, dark: 0xFFFFFF, alpha: (1, 0.13))
    static let track = adaptive(light: 0x1C1C28, dark: 0xFFFFFF, alpha: (0.05, 0.06))
    static let hairline = adaptive(light: 0x1C1C28, dark: 0xFFFFFF, alpha: (0.07, 0.08))
    static let edge = adaptive(light: 0xFFFFFF, dark: 0xFFFFFF, alpha: (0.7, 0.1))
    static let important = adaptive(light: 0xE8830C, dark: 0xFFB454)

    /// 卡片：左上偏白，右下带极淡的靛紫，渐变幅度保持在不抢内容的程度。
    static let card = LinearGradient(colors: [adaptive(light: 0xFFFFFF, dark: 0xFFFFFF, alpha: (0.86, 0.07)),
                                              adaptive(light: 0xF0EFFF, dark: 0x8B8CF8, alpha: (0.7, 0.06))],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cardHover = LinearGradient(colors: [adaptive(light: 0xFFFFFF, dark: 0xFFFFFF, alpha: (0.98, 0.1)),
                                                   adaptive(light: 0xEAE8FF, dark: 0x8B8CF8, alpha: (0.9, 0.11))],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)
    /// 上沿亮、下沿暗的描边，模拟玻璃受光。
    static let cardStroke = LinearGradient(colors: [edge, hairline], startPoint: .top, endPoint: .bottom)
    static let auroraStroke = LinearGradient(colors: [accentCool, accent, accentAlt],
                                             startPoint: .leading, endPoint: .trailing)

    private static func adaptive(light: UInt32, dark: UInt32, alpha: (CGFloat, CGFloat) = (1, 1)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: isDark ? alpha.1 : alpha.0)
        })
    }
}

/// 毛玻璃 + 色层 + 两团极淡的强调色光晕。
struct TodoBackdrop: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            TodoTheme.canvasTint
            RadialGradient(colors: [TodoTheme.accentAlt.opacity(0.14), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 260)
            RadialGradient(colors: [TodoTheme.accentCool.opacity(0.08), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 200)
        }
        .allowsHitTesting(false)
    }
}
