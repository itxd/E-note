import Foundation

// 作者：韦冬 2220285589@qq.com
struct TodoItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var category = "收集箱"
    var priority = "normal"
    var completed = false
    var dueAt: Date? = nil
    var number: Int? = nil
    var tagIDs: [UUID]? = nil
    var completedAt: Date? = nil
    var archivedAt: Date? = nil
    var archiveRestoredAt: Date? = nil
    var isArchived: Bool { archivedAt != nil }
    var canDelete: Bool { completed || isArchived }

    mutating func normalizeCompletion(previous: TodoItem?, now: Date = Date()) {
        if completed {
            if previous?.completed == false || completedAt == nil { completedAt = now }
        } else {
            completedAt = nil
            if previous?.completed == true { archivedAt = nil; archiveRestoredAt = nil }
        }
    }

    mutating func archiveIfDue(now: Date) {
        guard completed, archivedAt == nil, let completedAt = completedAt else { return }
        let start = max(completedAt, archiveRestoredAt ?? completedAt)
        if now.timeIntervalSince(start) >= 3 * 86400 { archivedAt = now }
    }
    var code: String { number.map { String(format: "T%06lld", Int64($0)) } ?? "待分配" }

    var taskLine: String {
        let mark = completed ? TaskSyntax.doneMark : TaskSyntax.openMark
        let priorityLabel = priority == "high" ? " [重要]" : ""
        return TaskSyntax.settingDue(mark + "[\(category.replacingOccurrences(of: "\n", with: " "))]\(priorityLabel) " + text.replacingOccurrences(of: "\n", with: " "), to: dueAt)
    }

    var overdue: Bool { !completed && !isArchived && dueAt.map { $0 < Date() } == true }
}

/// A popover edits one field against the task and account it was opened from.
struct TodoEditSession: Identifiable {
    let original: TodoItem
    let epoch: UUID
    var id: UUID { original.id }
}

enum TodoChange {
    case title(String, replacing: String)
    case dueDate(Date?, replacing: Date?)
    case toggleImportance
}
