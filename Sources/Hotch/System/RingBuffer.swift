import Foundation

/// Fixed-length history of the last `capacity` samples, oldest first.
/// Pre-filled with the first value it sees, and re-seeded the same way after a
/// gap (sampling paused, Mac asleep) so a chart never stitches stale data to new.
struct SystemRingBuffer: Sendable {
    let capacity: Int
    private var storage: [Double]
    private var head = 0 // index of the oldest sample
    private var lastDate: Date?

    init(capacity: Int, fill: Double = 0) {
        self.capacity = max(1, capacity)
        storage = Array(repeating: fill, count: self.capacity)
    }

    /// Oldest first, always `capacity` long.
    var values: [Double] {
        if head == 0 { return storage }
        var out = [Double]()
        out.reserveCapacity(capacity)
        out.append(contentsOf: storage[head...])
        out.append(contentsOf: storage[..<head])
        return out
    }

    mutating func fill(_ value: Double) {
        for i in 0..<capacity { storage[i] = value }
        head = 0
    }

    mutating func append(_ value: Double) {
        storage[head] = value
        head = (head + 1) % capacity
    }

    /// Appends, or re-seeds when this is the first sample or the previous one is
    /// older than `maxGap`.
    mutating func record(_ value: Double, at date: Date, maxGap: TimeInterval = 3.5) {
        let v = value.isFinite ? value : 0
        if let last = lastDate, date.timeIntervalSince(last) <= maxGap, date >= last {
            append(v)
        } else {
            fill(v)
        }
        lastDate = date
    }
}
