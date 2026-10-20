import AppKit

// Dragging a multi-selection inside one strip (Chrome: the selected tabs move as one block).
extension TabStripView {
    /// The other tabs of `id`'s multi-selection, in display order: they leave their slots for the
    /// drag (`gatheredIDs`). A tab outside the selection drags alone.
    func gatherCompanions(of id: TabID) {
        let selection = model.actionTabs(for: id)
        guard selection.count > 1 else { return }
        // A pinned tab and an unpinned one never share a region: only tabs of the dragged tab's kind move.
        let pinned = model.tab(id)?.isPinned ?? false
        let companions = selection.filter { $0 != id && model.tab($0)?.isPinned == pinned }
        guard !companions.isEmpty else { return }
        gatheredIDs = Set(companions)
        sync(fromModel: false, animating: false)
    }

    /// `gatheredIDs` in the order the model shows them.
    var displayedCompanions: [TabID] {
        model.orderedTabs.map(\.id).filter(gatheredIDs.contains)
    }

    /// The gathered tabs go back to their slots (a cancelled drag).
    func releaseCompanions() {
        guard !gatheredIDs.isEmpty else { return }
        gatheredIDs = []
        sync(fromModel: false)
    }

    /// The drop of a multi-selection: the block lands where the dragged tab was dropped, the
    /// dragged tab first and its companions after it in their order, all in the drop's group.
    func endSelectionDrag(_ drag: TabStripDrag) {
        gatheredIDs = []
        let block = [drag.id] + drag.companions
        guard displayed.contains(where: { $0.id == drag.id }) else { return sync(fromModel: true) }
        let regrouped = drag.targetGroup != drag.originalGroup
        let rest = displayed.map(\.id).filter { !block.contains($0) }
        let index = min(max(drag.currentIndex, 0), rest.count)
        var ids = rest
        ids.insert(contentsOf: block, at: index)
        let unchanged = ids == model.orderedTabs.map(\.id) && !regrouped
        if !unchanged {
            orderOverride = ids
            let membership: TabGroupMembershipChange = !regrouped ? .keep : drag.targetGroup.map { .join($0) } ?? .leave
            if case .join(let group) = membership { for id in block { groups.membershipOverride[id] = group } }
            if case .leave = membership { for id in block { groups.membershipOverride.updateValue(nil, forKey: id) } }
            sync(fromModel: false)
            model.send(.moveTabs(block, to: index, membership: membership))
        } else {
            sync(fromModel: false)
        }
        relayout(animated: !reduceMotion)
    }
}
