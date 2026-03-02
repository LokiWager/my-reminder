import Foundation

enum AssistantItemKind: String, Codable, CaseIterable, Sendable {
    case todo
    case shopping
}

struct AssistantItem: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: AssistantItemKind
    var title: String
    var isCompleted: Bool
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: AssistantItemKind,
        title: String,
        isCompleted: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.isCompleted = isCompleted
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum CalendarAccessState: Equatable, Sendable {
    case unknown
    case notDetermined
    case granted
    case denied
    case restricted
    case writeOnly
}

struct CalendarEventItem: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var startDate: Date
    var endDate: Date
    var calendarTitle: String
    var location: String?
    var isAllDay: Bool
}
