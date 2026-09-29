import Foundation

struct ChatMessage: Identifiable, Equatable {
    enum Direction {
        case incoming
        case outgoing
        case system
    }

    let id = UUID()
    let direction: Direction
    let text: String
    let timestamp: Date

    var isOutgoing: Bool { direction == .outgoing }

    static func incoming(_ text: String) -> ChatMessage {
        ChatMessage(direction: .incoming, text: text, timestamp: Date())
    }

    static func outgoing(_ text: String) -> ChatMessage {
        ChatMessage(direction: .outgoing, text: text, timestamp: Date())
    }

    static func system(_ text: String) -> ChatMessage {
        ChatMessage(direction: .system, text: text, timestamp: Date())
    }
}
