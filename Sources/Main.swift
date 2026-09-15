import AppKit

// E note — 作者：韦冬 2220285589@qq.com

@main
enum ENoteMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
