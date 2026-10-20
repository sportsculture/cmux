/// Index conversions for the daemon's `move-tab`.
public nonisolated enum TabMoveIndex {
    /// The wire index for moving a tab to `finalIndex` (its position after
    /// the move). `move-tab` takes insertion coordinates in the pre-move
    /// list: for a same-pane move the daemon removes the tab first and
    /// subtracts one from an index past it (cmux-tui spec "move-tab").
    /// `currentIndex` is the tab's index when it is already in the
    /// destination pane, else nil (cross-pane moves use the final index).
    public static func wireIndex(finalIndex: Int, currentIndex: Int?) -> Int {
        guard let currentIndex, finalIndex > currentIndex else { return max(0, finalIndex) }
        return finalIndex + 1
    }

    /// The final index in the pane's own (daemon) order for a strip drop
    /// that puts `moving` at `displayIndex` of the strip's display order.
    /// The strip shows pinned tabs first, group members together, closing
    /// tabs hidden and app-local tabs last, so a display index is not a
    /// pane index. The tab goes right before the pane tab that follows it
    /// in the new display order, else last.
    public static func paneFinalIndex(display: [String], moving: String, displayIndex: Int, pane: [String]) -> Int {
        var shown = display.filter { $0 != moving }
        shown.insert(moving, at: min(max(displayIndex, 0), shown.count))
        let others = pane.filter { $0 != moving }
        let after = shown.drop { $0 != moving }.dropFirst()
        return after.lazy.compactMap { others.firstIndex(of: $0) }.first ?? others.count
    }

    /// The position inside `group` for a strip drop that puts `moving` at
    /// `displayIndex` of the strip's display order: the members of `group`
    /// shown before it. `add-tabs-to-group` takes a position inside the
    /// group, the strip reports a display index.
    public static func groupIndex(display: [String], members: Set<String>, moving: String, displayIndex: Int) -> Int {
        let shown = display.filter { $0 != moving }
        return shown.prefix(min(max(displayIndex, 0), shown.count)).filter(members.contains).count
    }

    /// The final display index for step `step` of a block move: `block[step]` goes right after
    /// `block[step - 1]`, and the first tab right after the `restIndex`-th tab that is not in the
    /// block. `current` is the display order now, before this step's move.
    ///
    /// - Parameters:
    ///   - current: The display order before this step.
    ///   - block: The moving tabs, the dragged one first.
    ///   - step: Which tab of `block` moves now.
    ///   - restIndex: How many tabs outside the block go before it.
    /// - Returns: The display index `block[step]` moves to.
    public static func blockStepIndex(current: [String], block: [String], step: Int, restIndex: Int) -> Int {
        let moving = block[step]
        let others = current.filter { $0 != moving }
        if step > 0, let previous = others.firstIndex(of: block[step - 1]) { return previous + 1 }
        let members = Set(block)
        var seen = 0
        for (position, id) in others.enumerated() {
            if seen == restIndex { return position }
            if !members.contains(id) { seen += 1 }
        }
        return others.count
    }
}
