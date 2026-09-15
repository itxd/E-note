import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - 导出 / 导入

enum ExportImport {
    enum Format: String {
        case markdown = "md"
        case plainText = "txt"

        var ext: String { rawValue }
        var contentType: UTType {
            switch self {
            case .markdown: return UTType(filenameExtension: "md") ?? .plainText
            case .plainText: return .plainText
            }
        }
    }

    // MARK: 导出

    /// 每便签一个文件,选择目录
    static func exportToDirectory(format: Format) {
        let notes = NoteStore.shared.notes.filter { $0.deletedAt == nil }
        guard !notes.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择导出目录(每便签一个 .\(format.ext) 文件)"
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        var used: Set<String> = []
        for note in notes {
            let body = NoteStore.shared.body(of: note)
            let content = format == .markdown ? TaskSyntax.toMarkdown(body) : body
            let name = uniqueFileName(base: sanitized(note.title), ext: format.ext, used: &used)
            try? content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        alert("导出完成", "已导出 \(notes.count) 条便签到 \(dir.lastPathComponent)")
    }

    /// 合并单文件
    static func exportMerged(format: Format) {
        let notes = NoteStore.shared.notes.filter { $0.deletedAt == nil }
        guard !notes.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "E note 便签导出.\(format.ext)"
        panel.title = "导出为单个文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let merged = notes.map { note -> String in
            let body = NoteStore.shared.body(of: note)
            let content = format == .markdown ? TaskSyntax.toMarkdown(body) : body
            let header = format == .markdown ? "# \(note.title)" : "== \(note.title) =="
            return header + "\n\n" + content
        }.joined(separator: "\n\n---\n\n")
        try? merged.write(to: url, atomically: true, encoding: .utf8)
        alert("导出完成", "已导出 \(notes.count) 条便签")
    }

    // MARK: 导入

    static func importFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.message = "选择要导入的 Markdown / 纯文本文件"
        panel.prompt = "导入"
        guard panel.runModal() == .OK else { return }
        var count = 0
        for url in panel.urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let body = TaskSyntax.fromMarkdown(text)
            NoteStore.shared.create(body: body)
            count += 1
        }
        alert("导入完成", "已导入 \(count) 个文件为便签")
    }

    // MARK: 工具

    private static func sanitized(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = title.components(separatedBy: invalid).joined(separator: " ")
        return String(cleaned.prefix(40)).trimmingCharacters(in: .whitespaces)
    }

    private static func uniqueFileName(base: String, ext: String, used: inout Set<String>) -> String {
        let name = base.isEmpty ? "便签" : base
        var candidate = "\(name).\(ext)"
        var i = 2
        while used.contains(candidate) {
            candidate = "\(name)(\(i)).\(ext)"
            i += 1
        }
        used.insert(candidate)
        return candidate
    }

    private static func alert(_ message: String, _ info: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.runModal()
    }
}
