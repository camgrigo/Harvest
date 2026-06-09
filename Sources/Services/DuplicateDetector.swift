import Foundation

/// Finds likely-duplicate `Person` records by name (case-insensitive, allowing minor variations).
/// Pure and free of SwiftData fetches so it can be unit-tested with plain in-memory `Person`s.
enum DuplicateDetector {

    /// Likely-duplicate pairs among the active (non-archived) people, by name similarity.
    static func findDuplicates(in people: [Person]) -> Set<DuplicatePair> {
        let active = people.filter { !$0.isArchived }
        guard active.count > 1 else { return [] }
        var pairs: Set<DuplicatePair> = []
        for i in active.indices {
            for j in active.index(after: i)..<active.endIndex where isDuplicate(active[i], active[j]) {
                pairs.insert(DuplicatePair(active[i], active[j]))
            }
        }
        return pairs
    }

    /// True when two people are likely the same: same trimmed name (case-insensitive), one name
    /// contained in the other, or within a small edit distance (catches typos).
    private static func isDuplicate(_ p1: Person, _ p2: Person) -> Bool {
        let n1 = p1.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let n2 = p2.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !n1.isEmpty, !n2.isEmpty else { return false }

        if n1 == n2 { return true }
        // Substring containment (e.g. "Maria" vs "Maria Lopez"), but only for non-trivial names.
        if n1.count > 3, n2.count > 3, n1.contains(n2) || n2.contains(n1) { return true }
        // Close typos (e.g. "Maria" vs "Mariah"), for reasonably long names.
        if min(n1.count, n2.count) > 4, levenshtein(Array(n1), Array(n2)) <= 2 { return true }
        return false
    }

    /// Standard edit distance between two character arrays.
    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }
}

/// An unordered, hashable pair of `Person` ids, with a canonical ordering for stable de-duping.
struct DuplicatePair: Hashable {
    let id1: UUID
    let id2: UUID

    init(_ p1: Person, _ p2: Person) {
        let ids = [p1.id, p2.id].sorted { $0.uuidString < $1.uuidString }
        self.id1 = ids[0]
        self.id2 = ids[1]
    }
}
