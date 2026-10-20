import AppKit

/// One element of the in-process accessibility tree, as an accessibility client (VoiceOver, a
/// computer-use agent reading AXUIElement) reaches it.
struct AccessibilityNode {
    let role: NSAccessibility.Role
    let label: String
    let identifier: String
    /// Roles from the root down to this element, for failure messages.
    let path: String
}

/// Walks the accessibility tree under a view the way a client sees it (the attribute API AppKit
/// answers clients with, unignored elements only, hidden views skipped) and lists every control an agent could not
/// find or name: a pressable element without a label or a stable identifier, or an image that is
/// exposed without a description (decorative images must not be elements).
struct AccessibilityAudit {
    /// Roles an agent presses, toggles or drags: each needs a label and an identifier.
    let actionableRoles: Set<NSAccessibility.Role> = [
        .button, .menuButton, .popUpButton, .radioButton, .checkBox, .disclosureTriangle, .splitter, .slider,
    ]
    /// A guard against a cycle in a broken tree.
    let maxNodes = 5000

    /// Every element under `root` (the root included when it is an element).
    func nodes(under root: Any) -> [AccessibilityNode] {
        var out: [AccessibilityNode] = []
        var seen = Set<ObjectIdentifier>()
        walk(root, path: "", into: &out, seen: &seen)
        return out
    }

    /// One line per control an agent cannot use.
    func violations(under root: Any) -> [String] {
        nodes(under: root).compactMap { node in
            if actionableRoles.contains(node.role) {
                var missing: [String] = []
                if node.label.isEmpty { missing.append("label") }
                if node.identifier.isEmpty { missing.append("identifier") }
                return missing.isEmpty ? nil : "\(node.path) (\(node.label)) has no \(missing.joined(separator: " or "))"
            }
            if node.role == .image, node.label.isEmpty {
                return "\(node.path) is an unlabeled image (label it, or make it decorative)"
            }
            return nil
        }
    }

    /// The identifiers under `root`.
    func identifiers(under root: Any) -> Set<String> {
        Set(nodes(under: root).map(\.identifier).filter { !$0.isEmpty })
    }

    /// `object`'s attribute as an AX client reads it: AppKit answers clients through this entry
    /// point, which also covers views whose children AppKit computes (`accessibilityChildren()`
    /// returns nil for a plain view) and elements set with `setAccessibilityChildren`.
    private func attribute(_ object: NSObject, _ name: NSAccessibility.Attribute) -> Any? {
        object.accessibilityAttributeValue(name)
    }

    private func walk(_ object: Any, path: String, into out: inout [AccessibilityNode], seen: inout Set<ObjectIdentifier>) {
        guard out.count < maxNodes, let item = object as? NSObject, seen.insert(ObjectIdentifier(item)).inserted else { return }
        if let view = item as? NSView, view.isHiddenOrHasHiddenAncestor { return }
        let children = attribute(item, .children) as? [Any] ?? []
        var here = path
        // An ignored object's children stand in its place, as a client sees them.
        if !item.accessibilityIsIgnored(), let role = attribute(item, .role) as? String {
            let name = [NSAccessibility.Attribute.description, .title].compactMap { attribute(item, $0) as? String }.first { !$0.isEmpty } ?? ""
            let node = AccessibilityNode(role: NSAccessibility.Role(rawValue: role), label: name,
                                         identifier: attribute(item, .identifier) as? String ?? "",
                                         path: path.isEmpty ? role : "\(path) > \(role)")
            out.append(node)
            here = node.path
        }
        for child in children { walk(child, path: here, into: &out, seen: &seen) }
    }
}
