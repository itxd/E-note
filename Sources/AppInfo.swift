import AppKit

// E note
// 作者：韦冬 2220285589@qq.com
enum AppInfo {
    static let name = "E note"
    static let author = "韦冬"
    static let email = "2220285589@qq.com"

    static func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: name,
            .credits: NSAttributedString(string: "作者：\(author)\n\(email)")
        ])
    }
}
