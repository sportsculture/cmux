import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextTabs

// A dragged multi-selection dropped inside its own strip (`TabStripIntent.moveTabs`).
extension PaneController {
    /// Moves `ids` (the dragged tab first) next to each other, the first at final display index
    /// `index`, applying `membership` to all of them. Joining a group is one `add-tabs-to-group`
    /// at the drop's group position; otherwise the tabs move one by one, each after the previous.
    func moveTabs(_ ids: [StripTabID], to index: Int, membership: TabGroupMembershipChange) {
        let models = ids.compactMap { tab($0) }
        // An app-local tab (internal page, session browser tab) has no daemon slot.
        guard !models.isEmpty, models.count == ids.count else { return view.stripView.discardPendingReorder() }
        switch membership {
        case .join(let stripGroup):
            let position = StripOrder.groupIndex(index, moving: ids[0], group: stripGroup, in: self)
            groupCommand("add-tabs-to-group", groupWrites.add(models, to: TabGroupID_(stripGroup), index: position))
        case .leave:
            let grouped = models.filter { $0.tabGroup != nil }
            let remove = groupWrites.remove(grouped)
            Task {
                let ok = grouped.isEmpty ? true : await daemon.runGroupCommand("remove-tabs-from-group", intent: nil, remove)
                guard ok else { return resyncStrip() }
                moveBlock(ids, step: 0, restIndex: index)
            }
        case .keep:
            moveBlock(ids, step: 0, restIndex: index)
        }
    }

    /// Moves `block[step]` to its place (`TabMoveIndex.blockStepIndex`), then the next one.
    private func moveBlock(_ block: [StripTabID], step: Int, restIndex: Int) {
        guard step < block.count else { return StripOrder.settle([self]) }
        let id = block[step]
        guard let tab = tab(id) else { return resyncStrip() }
        let display = TabMoveIndex.blockStepIndex(current: orderedIDs.map(\.rawValue), block: block.map(\.rawValue),
                                                step: step, restIndex: restIndex)
        let paneIndex = StripOrder.paneIndex(forDisplayIndex: display, moving: id, in: self)
        TabMoves.move(tab, to: pane, index: paneIndex, services: services) { [weak self] ok in
            guard let self else { return }
            guard ok else { return self.resyncStrip() }
            self.moveBlock(block, step: step + 1, restIndex: restIndex)
        }
    }
}

extension PaneController {
    /// Moves `followers` (daemon tab ids, from any pane of this machine) into this pane right
    /// after `lead`, one by one in order, each joining `group` (nil: no group). A tab that is gone
    /// or on another machine is skipped (`TabMoves.move` refuses a cross-machine move).
    func moveFollowers(_ followers: [String], after lead: String, group: String?) {
        guard let next = followers.first else { return }
        let rest = Array(followers.dropFirst())
        guard let (tab, _) = services.locateTab(next) else { return moveFollowers(rest, after: lead, group: group) }
        let current = orderedIDs.map(\.rawValue).filter { $0 != next }
        let display = (current.firstIndex(of: lead) ?? current.count - 1) + 1
        let paneIndex = StripOrder.paneIndex(forDisplayIndex: display, moving: StripTabID(next), in: self)
        TabMoves.move(tab, to: pane, index: paneIndex, services: services) { [weak self] ok in
            guard let self else { return }
            guard ok else { return self.resyncStrip() }
            self.syncGroupMembership(of: tab, to: group)
            self.moveFollowers(rest, after: next, group: group)
            if rest.isEmpty { StripOrder.settle([self]) }
        }
    }
}
