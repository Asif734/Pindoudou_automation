import ApplicationServices
import CoreGraphics
import Foundation

enum BoundedTreeSearch {
    static func firstMatch<Node: Hashable, Value>(
        root: Node, maximumNodes: Int = 500, maximumDepth: Int = 40,
        timeLimit: TimeInterval = 1.5,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        cancelled: () -> Bool = { false },
        children: (Node) -> [Node], value: (Node) -> Value?
    ) -> Value? {
        guard maximumNodes > 0 else { return nil }
        let deadline = now() + timeLimit
        var visited: Set<Node> = [root]
        var queue: [(Node, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count {
            guard !cancelled(), now() < deadline else { return nil }
            let (node, depth) = queue[index]
            index += 1
            if let match = value(node) { return match }
            guard depth < maximumDepth, visited.count < maximumNodes,
                  !cancelled(), now() < deadline else { continue }
            for child in children(node) {
                guard visited.count < maximumNodes else { break }
                if visited.insert(child).inserted { queue.append((child, depth + 1)) }
            }
        }
        return nil
    }
}

/// Only read-only AX handles cross the actor boundary. No click or write is
/// performed by this worker, including after cancellation or a timeout.
struct PDDReadOnlyAXElement: @unchecked Sendable, Hashable {
    let element: AXUIElement
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
}

enum PDDChatPanelFrameSearch {
    static func find(root: PDDReadOnlyAXElement) -> CGRect? {
        BoundedTreeSearch.firstMatch(root: root, cancelled: { Task.isCancelled }, children: { node in
            let navigation = copy("AXChildrenInNavigationOrder", from: node.element) as? [AXUIElement] ?? []
            let children = navigation.isEmpty
                ? (copy(kAXChildrenAttribute as String, from: node.element) as? [AXUIElement] ?? []) : navigation
            return children.map { PDDReadOnlyAXElement(element: $0) }
        }, value: { node in
            // Bound each cross-process IPC as well as the whole traversal.
            AXUIElementSetMessagingTimeout(node.element, 0.2)
            let raw = copy("AXDOMClassList", from: node.element)
            let classes = (raw as? [String]) ?? (raw as? String).map { [$0] } ?? []
            guard classes.contains(where: {
                let value = $0.lowercased()
                return value.contains("middle-panel") || value.contains("chat-panel")
            }), let position = copy(kAXPositionAttribute as String, from: node.element),
                  let size = copy(kAXSizeAttribute as String, from: node.element),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions),
                  dimensions.width > 0, dimensions.height > 0 else { return nil }
            return CGRect(origin: point, size: dimensions)
        })
    }

    private static func copy(_ name: String, from element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
}
