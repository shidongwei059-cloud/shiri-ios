import ActivityKit
import Foundation

@available(iOS 16.1, *)
// Keep the registered attributes name so an app update can still find existing activities.
struct NianYiActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var targetDate: Date?
        var isHidden: Bool
        // Optional so activities created by an older app version still decode as timed cards.
        var isDateOnly: Bool? = nil
    }
    var cardID: String
    var occurrenceID: String
}

@available(iOS 16.1, *)
typealias ShiriActivityAttributes = NianYiActivityAttributes
