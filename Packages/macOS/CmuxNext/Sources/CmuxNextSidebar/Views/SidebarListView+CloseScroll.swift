import AppKit
import CmuxNextDesign
/// Sidebar scroll after a close, create or selection change
/// (plans/cmux-next/close-focus.md): `ListViewport.settle` decides the
/// offset; this file only reads geometry and applies it.
extension SidebarListViewComponents {
    /// Applies `layout` keeping what the user sees (the anchor stays put,
    /// rows and offset shift together so nothing jumps), then reveals the
    /// selection (`selectionReveal`) when it changed, or its row when it moved
    /// or was pushed out of view, by anyone (sidebar-focused-visible: the
    /// focused row is always in view); the reveal animates with `Motion`
    /// (instant under Reduce Motion, and to a new row, Cmd-N's, cx-evo3q) and
    /// is the only scroll this change makes.
    func applyKeepingViewport(_ layout: SidebarLayout, animated: Bool) {
        let active = selectionRevealKey
        let previousActive = revealedActive
        revealedActive = active
        // Read on every reload, so a user's move is used by the structural set that shows it, and only by that one.
        let userMoved = model.takeUserMove()
        guard drag == nil, external == nil, let clip = enclosingScrollView?.contentView,
              case let height = clip.bounds.height, height > 0 else {
            // No viewport yet (init): the first reload with one reveals.
            if (enclosingScrollView?.contentView.bounds.height ?? 0) <= 0 { revealedActive = nil }
            apply(layout, animated: animated)
            return
        }
        let before = displayed.viewport(height: height), after = layout.viewport(height: height)
        if displayed.rows.isEmpty {
            // First rows: show the active workspace, no animation.
            apply(layout, animated: false)
            if let extent = selectionReveal(in: layout, height: height) {
                scrollClip(to: after.reveal(extent, from: clip.bounds.minY, padding: SidebarLayout.revealPadding), animated: false)
            }
            return
        }
        let offset = clip.bounds.minY
        let anchored = after.anchored(from: before, offset: offset)
        let delta = anchored - offset
        if abs(delta) > 0.25 {
            RowMotion.shift(self, by: delta) // closing rows too; nothing draws until the offset moves with them
            Motion.withoutAnimation {
                // Rows and the offset move together: no visible change yet.
                if frame.height < after.content { setFrameSize(NSSize(width: frame.width, height: after.content)) }
                decorations.shift(by: delta)
                groupLineViews.shift(by: delta)
                // Rows are realized by `apply` from the new layout, not from
                // the old one while the offset moves.
                isShiftingViewport = true
                scrollClip(to: anchored, animated: false)
                isShiftingViewport = false
            }
        }
        apply(layout, animated: animated)
        let target = after.settle(from: before, offset: offset, focused: previousActive, newFocus: active,
                                  padding: SidebarLayout.revealPadding, userMoved: userMoved,
                                  extent: selectionReveal(in: layout, height: height))
        let toNewRow = active.map { before.item($0) == nil && after.item($0) != nil } ?? false
        if abs(target - clip.bounds.minY) > 0.25 { scrollClip(to: target, animated: animated && !toNewRow) }
    }

    /// The identity a reveal tracks for the selection: its workspace, group or
    /// item (a top item the list draws in a block too). Every entrypoint that
    /// selects (Cmd-1…9, Cmd-Ctrl-[ / ], the palette, the CLI, a click) changes
    /// `model.selectedItem`, so all of them reveal through this one key.
    var selectionRevealKey: SidebarRowKey? {
        switch model.selectedItem {
        case let .workspace(id)?: .workspace(id)
        case let .group(id)?: .group(id)
        case let .topItem(id)?: .item(id.rawValue)
        case nil: nil
        }
    }

    /// What revealing the selection shows in `layout` (a viewport `height`
    /// tall): the row that stands for it, or its item inside a block row, with
    /// the context `SidebarLayout.revealExtent` adds (the header above it, the
    /// list's top above the first stop). A selection that
    /// `SidebarItemOrder.revealsTop` (a top item, the first workspace under
    /// them) always reaches the list's top, also for a top item the band above
    /// the list draws (then the extent is the top alone, #22253). Nil when the
    /// list shows nothing for it.
    func selectionReveal(in layout: SidebarLayout, height: CGFloat) -> ListViewport<SidebarRowKey>.Item? {
        guard let id = selectionRevealKey else { return nil }
        var extent = listedReveal(id, in: layout, height: height)
        if model.itemOrder.revealsTop(for: model.selectedItem) {
            let end = extent.map { $0.start + $0.length } ?? 0
            // The top wins only while the item still fits below it.
            if end + SidebarLayout.revealPadding * 2 <= height || extent == nil { extent = .init(id: id, start: 0, length: end) }
        }
        return extent
    }

    /// `selectionReveal`'s row or block item, as the list draws it.
    private func listedReveal(_ id: SidebarRowKey, in layout: SidebarLayout, height: CGFloat) -> ListViewport<SidebarRowKey>.Item? {
        if let key = layout.selectedRowKey(for: model.selectedItem, in: model.sections) {
            return layout.revealExtent(id: id, row: key, height: height)
        }
        guard case let .topItem(item)? = model.selectedItem, let blocks,
              let section = blocks.sections.first(where: { $0.value.items.contains { $0.id == item } })?.key,
              let row = layout.row(for: .block(section)) else { return nil }
        // The block's region lays out at the row's origin (`SidebarBlockRowView`).
        let frame = blockContent(section, includeGap: false).flatMap { content in
            SidebarRegionView.layout(of: content, width: bounds.width).rows.first { $0.kind.itemID == item }?.frame
        }
        return layout.revealExtent(id: id, row: .block(section), span: frame.map { (row.y + $0.minY, $0.height) }, height: height)
    }
    func scrollClip(to y: CGFloat, animated: Bool) {
        enclosingScrollView?.scrollContent(toY: y, animated: animated) { [weak self] in self?.realizeVisibleRows() }
    }
}

private extension SidebarRegionRow.Kind {
    /// The item this region row draws, if any.
    var itemID: LayoutItemID? {
        switch self {
        case let .item(id, _), let .tile(id, _), let .chip(id, _): id
        case .header, .app: nil
        }
    }
}
