import SwiftUI

// 作者：韦冬 2220285589@qq.com
// 先约束文字，再整体旋转并交换布局宽高，避免旋转后的字形越过标签边缘。
struct TabTitle: View {
    let title: String
    let isPinned: Bool
    let width: CGFloat
    let height: CGFloat
    let vertical: Bool
    let scale: CGFloat
    var fontSize: CGFloat = 11

    private var inset: CGFloat { (vertical ? 10 : 5) * scale }
    private var textWidth: CGFloat { max(0, (vertical ? height : width) - inset * 2) }
    private var textHeight: CGFloat { max(0, (vertical ? width : height) - 10 * scale) }

    var body: some View {
        HStack(spacing: 3 * scale) {
            if isPinned {
                Circle()
                    .frame(width: 4 * scale, height: 4 * scale)
            }
            Text(title)
                .font(.system(size: fontSize * scale, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: textWidth, height: textHeight, alignment: vertical ? .trailing : .leading)
        .clipped()
        .rotationEffect(.degrees(vertical ? -90 : 0))
        .frame(width: vertical ? textHeight : textWidth,
               height: vertical ? textWidth : textHeight)
        .frame(width: width, height: height)
        .accessibilityLabel(title)
        .help(title)
    }
}
