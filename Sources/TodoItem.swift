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
    /// 旧数据没有该字段，解码为 nil，时效筛选按“三天前”处理。
    var createdAt: Date? = Date()
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

/// 按创建时间筛选；“三天内”按自然日计算，含今天。
enum TodoAge: Int, CaseIterable, Identifiable {
    case all, today, recent, older
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .all: return "全部时间"
        case .today: return "今天新增"
        case .recent: return "三天内新增"
        case .older: return "三天前的"
        }
    }

    func contains(_ item: TodoItem, now: Date, calendar: Calendar = .current) -> Bool {
        if self == .all { return true }
        let today = calendar.startOfDay(for: now)
        let recentStart = calendar.date(byAdding: .day, value: -2, to: today) ?? today
        guard let created = item.createdAt else { return self == .older }
        switch self {
        case .all: return true
        case .today: return created >= today
        case .recent: return created >= recentStart
        case .older: return created < recentStart
        }
    }
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
