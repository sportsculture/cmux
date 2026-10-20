extension TabStripModel {
    /// The selected tabs in display order: the shown tab and, while it is the active tab of
    /// ``multiSelection``, the tabs selected with it that the strip still has.
    public var selectedIDs: [TabID] {
        guard let selectedID else { return [] }
        guard let multi = multiSelection, multi.active == selectedID else { return [selectedID] }
        let all = multi.all
        return orderedTabs.map(\.id).filter(all.contains)
    }

    /// True when more than one tab is selected.
    public var hasMultiSelection: Bool { selectedIDs.count > 1 }

    /// The tabs an action on `id` applies to: the whole selection when `id` is in it, else
    /// only `id` (Chrome: right-clicking an unselected tab acts on that tab alone).
    public func actionTabs(for id: TabID) -> [TabID] {
        let selected = selectedIDs
        return selected.count > 1 && selected.contains(id) ? selected : [id]
    }

    /// What a click on `id` with `modifiers` selects (Chrome's tab strip rules):
    /// - no modifier: `id` alone;
    /// - Cmd: `id` toggles; added, it becomes the shown tab and the anchor; removed while it was
    ///   shown, the nearest selected tab shows; the last selected tab stays selected;
    /// - Shift: the range from the anchor to `id`, which shows; the anchor stays;
    /// - Cmd-Shift: that range added to the selection.
    public func clickOutcome(on id: TabID, modifiers: TabClickModifiers) -> TabClickOutcome {
        let modifiers = allowsMultiSelection ? modifiers : []
        let order = orderedTabs.map(\.id)
        guard order.contains(id) else { return TabClickOutcome(select: nil, selection: multiSelectionIfCurrent) }
        let current = Set(selectedIDs)
        let anchor = multiSelectionIfCurrent?.anchor ?? selectedID ?? id
        if modifiers.contains(.range) {
            guard let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) else {
                return TabClickOutcome(select: id, selection: nil)
            }
            var range = Set(order[min(a, b)...max(a, b)])
            if modifiers.contains(.toggle) { range.formUnion(current) }
            return outcome(active: id, all: range, anchor: anchor)
        }
        if modifiers.contains(.toggle) {
            if current.contains(id) {
                guard current.count > 1 else { return TabClickOutcome(select: nil, selection: multiSelectionIfCurrent) }
                let rest = current.subtracting([id])
                let active = id == selectedID ? Self.nearest(to: id, in: rest, order: order) : (selectedID ?? id)
                return outcome(active: active, all: rest, anchor: active)
            }
            return outcome(active: id, all: current.union([id]), anchor: id)
        }
        return TabClickOutcome(select: id, selection: nil)
    }

    /// Applies a click's outcome: stores the selection and asks the App to show its tab.
    public func apply(_ outcome: TabClickOutcome) {
        multiSelection = outcome.selection
        if let id = outcome.select, id != selectedID { send(.select(id)) }
    }

    /// Ends a multi-selection, keeping the shown tab.
    public func clearMultiSelection() {
        if multiSelection != nil { multiSelection = nil }
    }

    private var multiSelectionIfCurrent: TabMultiSelection? {
        guard let multi = multiSelection, multi.active == selectedID else { return nil }
        return multi
    }

    private func outcome(active: TabID, all: Set<TabID>, anchor: TabID) -> TabClickOutcome {
        let selection = all.count > 1 ? TabMultiSelection(active: active, others: all, anchor: anchor) : nil
        return TabClickOutcome(select: active, selection: selection)
    }

    /// The tab of `candidates` closest to `id` in `order`, preferring the right side (the tab that
    /// would show if `id` closed).
    private static func nearest(to id: TabID, in candidates: Set<TabID>, order: [TabID]) -> TabID {
        guard let index = order.firstIndex(of: id) else { return candidates.first ?? id }
        let ranked = order.enumerated().filter { candidates.contains($0.element) }
            .min { lhs, rhs in
                let l = abs(lhs.offset - index), r = abs(rhs.offset - index)
                return l != r ? l < r : lhs.offset > rhs.offset
            }
        return ranked?.element ?? id
    }
}
