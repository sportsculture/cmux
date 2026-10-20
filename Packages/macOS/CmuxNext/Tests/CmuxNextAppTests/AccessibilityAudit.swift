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

/// Walks the accessibility tree under a view the way a client sees it (`accessibilityChildren`,
/// unignored elements only, hidden views skipped) and lists every control an agent could not
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

    private func walk(_ object: Any, path: String, into out: inout [AccessibilityNode], seen: inout Set<ObjectIdentifier>) {
        guard out.count < maxNodes, let item = object as? NSObject, seen.insert(ObjectIdentifier(item)).inserted else { return }
        var here = path
        let children: [Any]
        if let view = item as? NSView {
            if view.isHiddenOrHasHiddenAncestor { return }
            if view.isAccessibilityElement(), let node = node(role: view.accessibilityRole(), label: view.accessibilityLabel(),
                                                               title: view.accessibilityTitle(),
                                                               identifier: view.accessibilityIdentifier() as String?, path: path) {
                out.append(node)
                here = node.path
            }
            children = view.accessibilityChildren() ?? []
        } else if let element = item as? NSAccessibilityElement {
            if element.isAccessibilityElement(), !element.isAccessibilityHidden(),
               let node = node(role: element.accessibilityRole(), label: element.accessibilityLabel(),
                               title: element.accessibilityTitle(), identifier: element.accessibilityIdentifier() as String?, path: path) {
                out.append(node)
                here = node.path
            }
            children = element.accessibilityChildren() ?? []
        } else {
            return
        }
        for child in children { walk(child, path: here, into: &out, seen: &seen) }
    }

    private func node(role: NSAccessibility.Role?, label: String?, title: String?, identifier: String?, path: String) -> AccessibilityNode? {
        guard let role else { return nil }
        let name = [label, title].compactMap(\.self).first { !$0.isEmpty } ?? ""
        return AccessibilityNode(role: role, label: name, identifier: identifier ?? "",
                                 path: path.isEmpty ? role.rawValue : "\(path) > \(role.rawValue)")
    }
}
