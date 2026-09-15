import Foundation
import CryptoKit
import AppKit
import SwiftUI

// MARK: - 路径

enum AppPaths {
    static let supportDir: URL = {
        // NOTY_DATA_DIR 便于测试/调试,正常使用无此环境变量
        if let override = ProcessInfo.processInfo.environment["NOTY_DATA_DIR"] {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fresh = home.appendingPathComponent("Library/Application Support/ENote", isDirectory: true)
        let legacy = home.appendingPathComponent("Library/Application Support/Noty", isDirectory: true)
        let fm = FileManager.default
        // 一次性迁移:新目录不存在且旧 Noty 目录存在时,把 note.key / notes.json 移过去。
        // 注意旧目录里可能有其他 app 的文件,只动我们自己的两个文件。
        if !fm.fileExists(atPath: fresh.path), fm.fileExists(atPath: legacy.path) {
            let backup = legacy.deletingLastPathComponent()
                .appendingPathComponent("Noty.migration-backup", isDirectory: true)
            let files = ["note.key", "notes.json"]
            // 先备份
            try? fm.createDirectory(at: backup, withIntermediateDirectories: true)
            for name in files {
                let src = legacy.appendingPathComponent(name)
                if fm.fileExists(atPath: src.path) {
                    try? fm.copyItem(at: src, to: backup.appendingPathComponent(name))
                }
            }
            // 再逐个移动;任一失败:把已移走的挪回,回退旧目录继续可用
            var moved: [String] = []
            var failed = false
            do {
                try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
                for name in files {
                    let src = legacy.appendingPathComponent(name)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    do {
                        try fm.moveItem(at: src, to: fresh.appendingPathComponent(name))
                        moved.append(name)
                    } catch {
                        failed = true
                        break
                    }
                }
            } catch {
                failed = true
            }
            if failed {
                for name in moved {
                    try? fm.moveItem(at: fresh.appendingPathComponent(name),
                                     to: legacy.appendingPathComponent(name))
                }
                try? fm.removeItem(at: fresh)
                return legacy
            }
            // 保持密钥文件 0600
            try? fm.setAttributes([.posixPermissions: 0o600],
                                  ofItemAtPath: fresh.appendingPathComponent("note.key").path)
        }
        try? fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        return fresh
    }()

    static var notesFile: URL { LocalProfile.directory.appendingPathComponent("notes.json") }
    static var keyFile: URL { supportDir.appendingPathComponent("note.key") }
}

// MARK: - AES-GCM 256 加解密(便签正文)

final class NoteCrypto {
    static let shared = NoteCrypto()
    let key: SymmetricKey

    private init() {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: AppPaths.keyFile), data.count == 32 {
            key = SymmetricKey(data: data)
            return
        }
        // Existing encrypted data must never be paired with a newly generated persisted key.
        let accountDir = AppPaths.supportDir.appendingPathComponent("accounts")
        if fm.fileExists(atPath: AppPaths.keyFile.path) || fm.fileExists(atPath: AppPaths.notesFile.path)
            || fm.fileExists(atPath: accountDir.path) {
            key = SymmetricKey(size: .bits256)
            return  // NoteStore detects the key mismatch and refuses writes/synchronization.
        }
        let newKey = SymmetricKey(size: .bits256)
        let raw = newKey.withUnsafeBytes { Data($0) }
        try? fm.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
        if fm.createFile(atPath: AppPaths.keyFile.path, contents: raw) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.keyFile.path)
        }
        key = newKey
    }

    /// 明文 -> base64(combined nonce+ciphertext+tag);空明文返回 ""
    func seal(_ plain: String) -> String {
        guard !plain.isEmpty,
              let data = plain.data(using: .utf8),
              let box = try? AES.GCM.seal(data, using: key),
              let combined = box.combined else { return "" }
        return combined.base64EncodedString()
    }

    func openChecked(_ sealed: String) throws -> String {
        if sealed.isEmpty { return "" }
        guard let data = Data(base64Encoded: sealed),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key),
              let text = String(data: plain, encoding: .utf8) else {
            throw APIError(500, "加密数据无法读取，请恢复完整的密钥与数据备份")
        }
        return text
    }

    func open(_ sealed: String) -> String { (try? openChecked(sealed)) ?? "" }
}

// MARK: - 调色板

struct NoteColor: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let paper: Color
    let tab: Color
    /// 纸面是否为深色(决定编辑器文字用白色)
    let isDark: Bool
    /// tab 上竖排标题的自适应颜色(按 tab 色亮度)
    let labelColor: Color

    init(name: String, paper: Color, tab: Color) {
        self.name = name
        self.paper = paper
        self.tab = tab
        func lum(_ c: NSColor) -> CGFloat {
            0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }
        let p = NSColor(paper).usingColorSpace(.sRGB) ?? NSColor(paper)
        let t = NSColor(tab).usingColorSpace(.sRGB) ?? NSColor(tab)
        self.isDark = lum(p) < 0.5
        self.labelColor = lum(t) > 0.55 ? Color.black.opacity(0.65) : Color.white.opacity(0.95)
    }

    /// 专属色不进入普通便签色盘，保证 TODOList 始终容易辨认。
    static let todo = NoteColor(name: "松柏绿",
        paper: Color(red: 0.933, green: 0.957, blue: 0.941),
        tab: Color(red: 0.220, green: 0.427, blue: 0.388))
    static let defaultNames = ["杏砂", "雾紫"]

    /// 八色调色板：两种柔和默认色，加六种可手选颜色。
    static let all: [NoteColor] = [
        NoteColor(name: "珊瑚红", paper: Color(red: 1.00, green: 0.87, blue: 0.83, opacity: 1),
                  tab: Color(red: 0.94, green: 0.42, blue: 0.36, opacity: 1)),
        NoteColor(name: "蜜橙", paper: Color(red: 1.00, green: 0.91, blue: 0.78, opacity: 1),
                  tab: Color(red: 0.96, green: 0.62, blue: 0.22, opacity: 1)),
        NoteColor(name: "鹅黄", paper: Color(red: 1.00, green: 0.96, blue: 0.72, opacity: 1),
                  tab: Color(red: 0.98, green: 0.82, blue: 0.20, opacity: 1)),
        NoteColor(name: "嫩绿", paper: Color(red: 0.87, green: 0.95, blue: 0.82, opacity: 1),
                  tab: Color(red: 0.42, green: 0.74, blue: 0.38, opacity: 1)),
        NoteColor(name: "青", paper: Color(red: 0.82, green: 0.94, blue: 0.92, opacity: 1),
                  tab: Color(red: 0.24, green: 0.70, blue: 0.66, opacity: 1)),
        NoteColor(name: "雾紫", paper: Color(red: 0.957, green: 0.949, blue: 0.980),
                  tab: Color(red: 0.784, green: 0.761, blue: 0.875)),
        NoteColor(name: "杏砂", paper: Color(red: 0.988, green: 0.961, blue: 0.925),
                  tab: Color(red: 0.906, green: 0.784, blue: 0.659)),
        NoteColor(name: "紫罗兰", paper: Color(red: 0.90, green: 0.86, blue: 0.99, opacity: 1),
                  tab: Color(red: 0.58, green: 0.45, blue: 0.90, opacity: 1)),
    ]

    /// 旧版本数据里的颜色名,保持可解析,不再进调色板。
    /// 旧默认深蓝/天蓝在加载时迁移为杏砂/雾紫；其余旧色仍可解析。
    /// 其余旧名保留原色,不再重复列出。
    private static let legacy: [NoteColor] = [
        NoteColor(name: "鲑鱼粉", paper: Color(red: 1.00, green: 0.88, blue: 0.83, opacity: 1),
                  tab: Color(red: 0.95, green: 0.55, blue: 0.42, opacity: 1)),
        NoteColor(name: "玫红", paper: Color(red: 0.99, green: 0.83, blue: 0.88, opacity: 1),
                  tab: Color(red: 0.87, green: 0.33, blue: 0.53, opacity: 1)),
        NoteColor(name: "紫", paper: Color(red: 0.89, green: 0.85, blue: 0.99, opacity: 1),
                  tab: Color(red: 0.56, green: 0.46, blue: 0.91, opacity: 1)),
        NoteColor(name: "蓝", paper: Color(red: 0.80, green: 0.89, blue: 1.00, opacity: 1),
                  tab: Color(red: 0.36, green: 0.60, blue: 0.95, opacity: 1)),
        NoteColor(name: "灰绿", paper: Color(red: 0.86, green: 0.90, blue: 0.84, opacity: 1),
                  tab: Color(red: 0.56, green: 0.67, blue: 0.53, opacity: 1)),
        NoteColor(name: "绿", paper: Color(red: 0.83, green: 0.94, blue: 0.81, opacity: 1),
                  tab: Color(red: 0.36, green: 0.72, blue: 0.43, opacity: 1)),
        NoteColor(name: "墨黑", paper: Color(red: 0.32, green: 0.33, blue: 0.35, opacity: 1),
                  tab: Color(red: 0.16, green: 0.17, blue: 0.19, opacity: 1)),
        NoteColor(name: "樱粉", paper: Color(red: 1.00, green: 0.82, blue: 0.85, opacity: 1),
                  tab: Color(red: 0.97, green: 0.52, blue: 0.62, opacity: 1)),
        NoteColor(name: "薄荷", paper: Color(red: 0.78, green: 0.94, blue: 0.78, opacity: 1),
                  tab: Color(red: 0.40, green: 0.78, blue: 0.45, opacity: 1)),
        NoteColor(name: "薰衣草", paper: Color(red: 0.87, green: 0.82, blue: 0.98, opacity: 1),
                  tab: Color(red: 0.62, green: 0.50, blue: 0.92, opacity: 1)),
        NoteColor(name: "云雾", paper: Color(red: 0.92, green: 0.92, blue: 0.90, opacity: 1),
                  tab: Color(red: 0.55, green: 0.56, blue: 0.58, opacity: 1)),
    ]

    static func named(_ name: String) -> NoteColor {
        if name == todo.name { return todo }
        let mapped = name == "深蓝" ? "杏砂" : (name == "天蓝" ? "雾紫" : name)
        return all.first { $0.name == mapped } ?? legacy.first { $0.name == mapped } ?? all[0]
    }
}

// MARK: - 任务行语法

enum TaskSyntax {
    static let openMark = "☐ "
    static let doneMark = "☑ "
    /// 行尾到期时间标记
    static let dueMark = "⏰"

    static func isTask(_ line: String) -> Bool {
        trimmed(line).hasPrefix(openMark) || trimmed(line).hasPrefix(doneMark)
    }

    static func isDone(_ line: String) -> Bool {
        trimmed(line).hasPrefix(doneMark)
    }

    private static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    // MARK: 到期时间(行尾 `⏰yyyy-MM-dd HH:mm`)

    private static let dueRegex = try? NSRegularExpression(
        pattern: "[ \\t]*⏰(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2})[ \\t]*$")

    /// 在去掉行尾换行的行上匹配(换行不属于标记)
    private static func matchDue(_ line: String) -> NSTextCheckingResult? {
        guard let regex = dueRegex else { return nil }
        var s = line
        if s.hasSuffix("\n") { s.removeLast() }
        return regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    /// 任务行的到期时间;无标记或解析失败返回 nil
    static func dueDate(of line: String) -> Date? {
        guard isTask(line), let m = matchDue(line), m.numberOfRanges == 6 else { return nil }
        let ns = line as NSString
        var comps = DateComponents()
        comps.calendar = Calendar.current
        comps.year = Int(ns.substring(with: m.range(at: 1)))
        comps.month = Int(ns.substring(with: m.range(at: 2)))
        comps.day = Int(ns.substring(with: m.range(at: 3)))
        comps.hour = Int(ns.substring(with: m.range(at: 4)))
        comps.minute = Int(ns.substring(with: m.range(at: 5)))
        return comps.date
    }

    /// 行内到期标记(含前导空格,不含行尾换行)的 range;无标记返回 nil
    static func dueMarkerRange(in line: String) -> NSRange? {
        matchDue(line)?.range
    }

    /// 去掉行尾到期标记后的行(保留换行)
    static func removingDue(_ line: String) -> String {
        guard let r = dueMarkerRange(in: line) else { return line }
        let ns = line as NSString
        return ns.replacingCharacters(in: r, with: "")
    }

    static func formatDue(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// 给任务行设置/清除到期时间(假定该行已是任务行)
    static func settingDue(_ line: String, to date: Date?) -> String {
        let hadNewline = line.hasSuffix("\n")
        var base = removingDue(line)
        if base.hasSuffix("\n") { base.removeLast() }
        if let date = date {
            base += " \(dueMark)" + formatDue(date)
        }
        return hadNewline ? base + "\n" : base
    }

    /// 扫描正文,返回最早一个未完成且已到期的时间(没有则 nil)
    static func earliestOverdueDue(_ body: String, now: Date) -> Date? {
        var earliest: Date? = nil
        body.enumerateLines { line, _ in
            guard !isDone(line), let due = dueDate(of: line), due < now else { return }
            if earliest == nil || due < earliest! { earliest = due }
        }
        return earliest
    }

    /// 导出为 Markdown 任务语法(⏰ 转成 📅,兼容 Tasks 插件)
    static func toMarkdown(_ body: String) -> String {
        body.components(separatedBy: "\n").map { line in
            let t = trimmed(line)
            if t.hasPrefix(openMark) { return "- [ ] " + String(line.dropFirst(openMark.count)) }
            if t.hasPrefix(doneMark) { return "- [x] " + String(line.dropFirst(doneMark.count)) }
            return line
        }.joined(separator: "\n")
    }

    /// 从 Markdown 任务语法读回(📅 还原为 ⏰)
    static func fromMarkdown(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let t = trimmed(line)
            var converted = line
            if t.hasPrefix("- [ ]") { converted = openMark + String(line.dropFirst("- [ ]".count)) }
            if t.hasPrefix("- [x]") || t.hasPrefix("- [X]") { converted = doneMark + String(line.dropFirst("- [x]".count)) }
            return converted.replacingOccurrences(of: "📅", with: dueMark)
        }.joined(separator: "\n")
    }
}

// MARK: - 便签模型

struct NoteRecord: Codable, Identifiable, Hashable {
    static let todoListTitle = "待办清单"

    var id: UUID
    var title: String
    var colorName: String
    var createdAt: Date
    var modifiedAt: Date
    var isPinned: Bool
    var isArchived: Bool
    /// 删除时间;非 nil 表示在"已删除"区(软删除)。旧数据无此字段,解码为 nil
    var deletedAt: Date?
    /// base64(AES-GCM sealed box),"" 表示空正文
    var body: String
    /// 旧便签缺省为 nil；TODO 元数据与正文同样加密。
    var kind: String? = nil
    var todoData: String? = nil
    var tagData: String? = nil
    /// 已分配的最大 TODO 编号，删除任务后也不回退。
    var todoSequence: Int? = nil
    var linkedTodoID: UUID? = nil
    var workflowID: UUID? = nil
    var isTodoList: Bool { kind == "todoList" }

    static func make(colorName: String = "雾紫") -> NoteRecord {
        NoteRecord(id: UUID(),
                   title: "新便签",
                   colorName: colorName,
                   createdAt: Date(),
                   modifiedAt: Date(),
                   isPinned: false,
                   isArchived: false,
                   deletedAt: nil,
                   body: "")
    }
}

func deriveTitle(from body: String) -> String {
    guard let first = body.split(separator: "\n", omittingEmptySubsequences: true).first else { return "新便签" }
    let trimmed = first.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? "新便签" : String(trimmed.prefix(40))
}

func formatNoteDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "yyyy年M月d日 HH:mm"
    return f.string(from: date)
}

func relativeTimeString(from date: Date, to now: Date) -> String {
    let s = Int(now.timeIntervalSince(date))
    if s < 8 { return "刚刚" }
    if s < 60 { return "\(s) 秒前" }
    if s < 3600 { return "\(s / 60) 分钟前" }
    if s < 86400 { return "\(s / 3600) 小时前" }
    return formatNoteDate(date)
}
