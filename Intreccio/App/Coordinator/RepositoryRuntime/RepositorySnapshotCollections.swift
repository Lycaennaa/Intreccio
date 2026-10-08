import Foundation

// Published snapshots retain prior roots; path-copying keeps collection copies O(1) and point updates O(log n).

private final class RepositorySnapshotMapNode<Value: Sendable>: Sendable {
    let key: UUID
    let value: Value
    let priority: UInt64
    let left: RepositorySnapshotMapNode<Value>?
    let right: RepositorySnapshotMapNode<Value>?
    let count: Int

    // Keep an explicit deinitializer to avoid a Swift 6.3.3 optimizer crash for this recursive node.
    deinit {}
    nonisolated init(
        key: UUID,
        value: Value,
        priority: UInt64,
        left: RepositorySnapshotMapNode<Value>?,
        right: RepositorySnapshotMapNode<Value>?
    ) {
        self.key = key
        self.value = value
        self.priority = priority
        self.left = left
        self.right = right
        count = 1 + (left?.count ?? 0) + (right?.count ?? 0)
    }
}

nonisolated struct RepositorySnapshotMap<Value: Sendable>: Sendable {
    private typealias Node = RepositorySnapshotMapNode<Value>

    private let root: Node?

    init() {
        root = nil
    }

    init(_ values: [UUID: Value]) {
        var result = Self()
        for (key, value) in values {
            result = result.setting(value, for: key)
        }
        self = result
    }

    private init(root: Node?) {
        self.root = root
    }

    var count: Int { root?.count ?? 0 }
    var isEmpty: Bool { root == nil }

    subscript(key: UUID) -> Value? {
        var node = root
        while let current = node {
            if key == current.key { return current.value }
            node = Self.comesBefore(key, current.key) ? current.left : current.right
        }
        return nil
    }

    subscript(key: UUID, default defaultValue: @autoclosure () -> Value) -> Value {
        self[key] ?? defaultValue()
    }

    var keys: [UUID] {
        var result: [UUID] = []
        result.reserveCapacity(count)
        Self.appendKeys(root, to: &result)
        return result
    }

    var values: [Value] {
        var result: [Value] = []
        result.reserveCapacity(count)
        Self.appendValues(root, to: &result)
        return result
    }

    var entries: [(key: UUID, value: Value)] {
        var result: [(key: UUID, value: Value)] = []
        result.reserveCapacity(count)
        Self.appendEntries(root, to: &result)
        return result
    }

    func setting(_ value: Value?, for key: UUID) -> Self {
        let root: Node?
        if let value {
            root = Self.inserting(
                self.root,
                key: key,
                value: value,
                priority: Self.priority(for: key)
            )
        } else {
            root = Self.removing(self.root, key: key)
        }
        return Self(root: root)
    }

    func filtering(_ isIncluded: (UUID, Value) -> Bool) -> Self {
        var result = Self()
        for entry in entries where isIncluded(entry.key, entry.value) {
            result = result.setting(entry.value, for: entry.key)
        }
        return result
    }

    private static func comesBefore(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }

    private static func priority(for key: UUID) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(key)
        return UInt64(truncatingIfNeeded: hasher.finalize())
    }

    private static func makeNode(
        key: UUID,
        value: Value,
        priority: UInt64,
        left: Node?,
        right: Node?
    ) -> Node {
        Node(
            key: key,
            value: value,
            priority: priority,
            left: left,
            right: right
        )
    }

    private static func inserting(
        _ root: Node?,
        key: UUID,
        value: Value,
        priority: UInt64
    ) -> Node {
        guard let root else {
            return makeNode(key: key, value: value, priority: priority, left: nil, right: nil)
        }
        if key == root.key {
            return makeNode(
                key: key,
                value: value,
                priority: root.priority,
                left: root.left,
                right: root.right
            )
        }
        if priority > root.priority {
            let (left, right) = split(root, at: key)
            return makeNode(key: key, value: value, priority: priority, left: left, right: right)
        }
        if comesBefore(key, root.key) {
            return makeNode(
                key: root.key,
                value: root.value,
                priority: root.priority,
                left: inserting(root.left, key: key, value: value, priority: priority),
                right: root.right
            )
        }
        return makeNode(
            key: root.key,
            value: root.value,
            priority: root.priority,
            left: root.left,
            right: inserting(root.right, key: key, value: value, priority: priority)
        )
    }

    private static func removing(_ root: Node?, key: UUID) -> Node? {
        guard let root else { return nil }
        if key == root.key { return merging(root.left, root.right) }
        if comesBefore(key, root.key) {
            return makeNode(
                key: root.key,
                value: root.value,
                priority: root.priority,
                left: removing(root.left, key: key),
                right: root.right
            )
        }
        return makeNode(
            key: root.key,
            value: root.value,
            priority: root.priority,
            left: root.left,
            right: removing(root.right, key: key)
        )
    }

    private static func split(_ root: Node?, at key: UUID) -> (Node?, Node?) {
        guard let root else { return (nil, nil) }
        if comesBefore(root.key, key) {
            let (left, right) = split(root.right, at: key)
            return (
                makeNode(
                    key: root.key,
                    value: root.value,
                    priority: root.priority,
                    left: root.left,
                    right: left
                ),
                right
            )
        }
        let (left, right) = split(root.left, at: key)
        return (
            left,
            makeNode(
                key: root.key,
                value: root.value,
                priority: root.priority,
                left: right,
                right: root.right
            )
        )
    }

    private static func merging(_ lhs: Node?, _ rhs: Node?) -> Node? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        if lhs.priority > rhs.priority {
            return makeNode(
                key: lhs.key,
                value: lhs.value,
                priority: lhs.priority,
                left: lhs.left,
                right: merging(lhs.right, rhs)
            )
        }
        return makeNode(
            key: rhs.key,
            value: rhs.value,
            priority: rhs.priority,
            left: merging(lhs, rhs.left),
            right: rhs.right
        )
    }

    private static func appendKeys(_ node: Node?, to result: inout [UUID]) {
        guard let node else { return }
        appendKeys(node.left, to: &result)
        result.append(node.key)
        appendKeys(node.right, to: &result)
    }

    private static func appendValues(_ node: Node?, to result: inout [Value]) {
        guard let node else { return }
        appendValues(node.left, to: &result)
        result.append(node.value)
        appendValues(node.right, to: &result)
    }

    private static func appendEntries(
        _ node: Node?,
        to result: inout [(key: UUID, value: Value)]
    ) {
        guard let node else { return }
        appendEntries(node.left, to: &result)
        result.append((key: node.key, value: node.value))
        appendEntries(node.right, to: &result)
    }
#if DEBUG
    var isValidForTesting: Bool {
        var previousKey: UUID?
        let result = Self.validate(root, previousKey: &previousKey)
        return result.isValid && result.count == count
    }

    private static func validate(
        _ node: Node?,
        previousKey: inout UUID?
    ) -> (isValid: Bool, count: Int) {
        guard let node else { return (true, 0) }
        let left = validate(node.left, previousKey: &previousKey)
        guard left.isValid,
              node.priority == priority(for: node.key),
              node.left.map({ $0.priority <= node.priority }) ?? true,
              node.right.map({ $0.priority <= node.priority }) ?? true else {
            return (false, 0)
        }
        if let previousKey, !comesBefore(previousKey, node.key) {
            return (false, 0)
        }
        previousKey = node.key
        let right = validate(node.right, previousKey: &previousKey)
        guard right.isValid else { return (false, 0) }
        let count = 1 + left.count + right.count
        return (node.count == count, count)
    }
#endif
}

extension RepositorySnapshotMap: Equatable where Value: Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.entries.elementsEqual(rhs.entries) {
            $0.key == $1.key && $0.value == $1.value
        }
    }
}

extension RepositorySnapshotMap: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (UUID, Value)...) {
        var result = Self()
        for (key, value) in elements {
            result = result.setting(value, for: key)
        }
        self = result
    }
}

nonisolated struct RepositorySnapshotSet: Sendable, Equatable {
    private let storage: RepositorySnapshotMap<Bool>

    init() {
        storage = RepositorySnapshotMap()
    }

    init(_ values: Set<UUID>) {
        var storage = RepositorySnapshotMap<Bool>()
        for value in values {
            storage = storage.setting(true, for: value)
        }
        self.storage = storage
    }

    private init(storage: RepositorySnapshotMap<Bool>) {
        self.storage = storage
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    func contains(_ value: UUID) -> Bool {
        storage[value] == true
    }

    func inserting(_ value: UUID) -> Self {
        Self(storage: storage.setting(true, for: value))
    }

    func removing(_ value: UUID) -> Self {
        Self(storage: storage.setting(nil, for: value))
    }

    var elements: [UUID] { storage.keys }

    nonisolated static func == (lhs: Self, rhs: Set<UUID>) -> Bool {
        lhs == Self(rhs)
    }
}
nonisolated func == (lhs: Set<UUID>, rhs: RepositorySnapshotSet) -> Bool {
    rhs == lhs
}
