public enum DurabilityState: String, Sendable, Codable, CaseIterable, Equatable {
    case staged
    case journaled
    case committed
    case conflicted
}
