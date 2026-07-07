import Foundation
import Observation

// A single token-usage event pulled from a transcript line.
struct UsageEvent {
    let date: Date
    let tokens: Int
}

// The tiny, already-computed view model handed to the UI. Nothing else crosses threads.
struct UsageSnapshot: Equatable {
    var fiveHourTokens = 0
    var sevenDayTokens = 0
    var windowStart: Date? = nil
    var nextReset: Date? = nil
    var lastProject: String? = nil
    var lastActivity: Date? = nil
}

// One observable holder shared by the SwiftUI hierarchies. Unchanged subtrees don't re-render.
@Observable final class UsageStore {
    var snapshot = UsageSnapshot()
}

// Minimal decodable matching Claude Code assistant transcript lines. Unknown fields ignored.
struct TranscriptLine: Decodable {
    let type: String?
    let timestamp: String?
    let message: Message?

    struct Message: Decodable { let usage: Usage? }
    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
    }
}
