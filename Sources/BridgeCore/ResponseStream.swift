import Foundation

/// Observes complete SSE events without changing a single response byte.
/// Text/item completion is not response completion; only a typed terminal event counts.
public struct ResponseStreamObserver {
    public private(set) var terminalEvent: String?
    public private(set) var lastEvent: String?
    private var line = Data()
    private var eventData = Data()
    private var previousWasCR = false
    private var oversized = false
    private static let limit = 2 * 1024 * 1024
    public init() {}
    public mutating func append(_ bytes: Data) {
        guard terminalEvent == nil else { return }
        for byte in bytes {
            if byte == 10 && previousWasCR { previousWasCR = false; continue }
            previousWasCR = byte == 13
            if byte == 10 || byte == 13 {
                consumeLine(); line.removeAll(keepingCapacity: true)
                if terminalEvent != nil { return }
            } else if line.count < Self.limit { line.append(byte) }
            else { oversized = true }
        }
    }
    private mutating func consumeLine() {
        if line.isEmpty {
            if !oversized, let object = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
               let type = object["type"] as? String {
                // Do not retain arbitrary upstream strings as diagnostic data.
                if type.hasPrefix("response."), type.count < 80 { lastEvent = type }
                if ["response.completed", "response.failed", "response.incomplete"].contains(type) { terminalEvent = type }
            }
            eventData.removeAll(keepingCapacity: true); oversized = false
        } else if line.starts(with: Data("data:".utf8)), !oversized {
            var value = line.dropFirst(5)
            if value.first == 32 { value = value.dropFirst() }
            if eventData.count + value.count + 1 > Self.limit { oversized = true; eventData.removeAll(); return }
            if !eventData.isEmpty { eventData.append(10) }
            eventData.append(contentsOf: value)
        }
    }
}
