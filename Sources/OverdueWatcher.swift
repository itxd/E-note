import Foundation
import AppKit

// 作者：韦冬 2220285589@qq.com
// 只扫描 TODOList 结构化任务；普通 note 的文本待办不触发探出提醒。
final class OverdueWatcher: ObservableObject {
    static let shared = OverdueWatcher()
    @Published private(set) var upcomingTaskIDs: Set<UUID> = []
    @Published private(set) var overdueTaskIDs: Set<UUID> = []
    @Published private(set) var reminderNoteID: UUID?
    var hasTodoReminder: Bool { reminderNoteID != nil }

    private var timer: Timer?
    private var pendingWork: DispatchWorkItem?
    private init() {}

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refreshSoon() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func refresh(now: Date = Date()) {
        NoteStore.shared.maintainTodoArchives(now: now)
        let settings = AppSettings.shared
        let tasks = NoteStore.shared.todos().filter { !$0.completed && !$0.isArchived && $0.dueAt != nil }
        let overdue = Set(tasks.filter { $0.dueAt! <= now }.map { $0.id })
        let upcoming = Set(tasks.filter {
            $0.dueAt! > now && $0.dueAt! <= now.addingTimeInterval(Double(settings.todoReminderMinutes) * 60)
        }.map { $0.id })
        let noteID = settings.todoListEnabled && settings.todoReminderEnabled && (!overdue.isEmpty || !upcoming.isEmpty)
            ? NoteStore.shared.todoList?.id : nil
        guard overdue != overdueTaskIDs || upcoming != upcomingTaskIDs || noteID != reminderNoteID else { return }
        overdueTaskIDs = overdue
        upcomingTaskIDs = upcoming
        reminderNoteID = noteID
        NotificationCenter.default.post(name: .notyOverdueChanged, object: nil)
    }

    func isOverdue(_ noteID: UUID) -> Bool {
        noteID == reminderNoteID && !overdueTaskIDs.isEmpty
    }
    func isDueSoon(_ noteID: UUID) -> Bool {
        noteID == reminderNoteID && overdueTaskIDs.isEmpty && !upcomingTaskIDs.isEmpty
    }
}

extension Notification.Name {
    static let notyOverdueChanged = Notification.Name("NotyOverdueChanged")
}

// MARK: - 已删除区 30 天自动清除(启动时 + 每 6 小时)

enum DeletedNotesMaintenance {
    static func run() {
        NoteStore.shared.purgeDeleted(olderThan: 30)
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            NoteStore.shared.purgeDeleted(olderThan: 30)
        }
    }
}
