import Foundation

/// Canonical ordering keeps backup digests stable after decoding a Set on another process/device.
@propertyWrapper
public struct SortedSet<Element: Hashable & Codable & Comparable & Sendable>: Codable, Equatable, Sendable {
    public var wrappedValue: Set<Element>
    public init(wrappedValue: Set<Element>) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws { wrappedValue = Set(try decoder.singleValueContainer().decode([Element].self)) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(wrappedValue.sorted()) }
}
