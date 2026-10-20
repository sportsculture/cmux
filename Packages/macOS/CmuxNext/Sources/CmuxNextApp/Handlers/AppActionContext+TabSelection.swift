import CmuxNextActions
import CmuxNextDaemon
import CmuxNextTabs
import Foundation

// The tabs a tab action applies to. Every entrypoint (the tab menu, the palette, a shortcut, the
// CLI, MCP) resolves them here, so a right-click and Cmd-Shift-P on the same tab act on the same
// tabs: the targeted (or focused) tab and, when it is in its strip's multi-selection, every
// selected tab (`TabStripModel.actionTabs(for:)`).
extension AppActionContext {
    /// Name of the optional argument that lists tabs by id (comma-separated), for the CLI and MCP.
    static let tabsArgument = "tabs"

    /// The tabs an action on a tab acts on, in display order, with their pane: the `tabs`
    /// argument when given (all in one pane), else the targeted or focused tab with the rest of
    /// its strip's multi-selection. Refuses like ``daemonTab(_:)``.
    func actionTabs(_ invocation: ActionInvocation) -> (tabs: [TabModel], pane: PaneModel)? {
        if let list = invocation[Self.tabsArgument]?.stringValue {
            let ids = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var found: [(TabModel, PaneModel)] = []
            for id in ids {
                guard let hit = services.locateTab(id) ?? notFound(RefusalStrings.noTab(id)) else { return nil }
                found.append(hit)
            }
            guard let pane = found.first?.1 ?? refuse(RefusalStrings.noTab(list)) else { return nil }
            guard found.allSatisfy({ $0.1 === pane }) else { return refuse(RefusalStrings.tabsInDifferentPanes) }
            return (found.map(\.0), pane)
        }
        guard let (tab, pane) = daemonTab(invocation) else { return nil }
        guard let controller = services.paneController(for: pane) else { return ([tab], pane) }
        let tabs = controller.stripModel.actionTabs(for: StripTabID(tab.id)).compactMap { controller.tab($0) }
        return (tabs.contains { $0.id == tab.id } ? tabs : [tab], pane)
    }

    /// How many tabs an action on this invocation's tab acts on, without refusing (menu and
    /// palette titles). 1 when it resolves to one tab or none.
    func actionTabCount(_ invocation: ActionInvocation) -> Int {
        if let list = invocation[Self.tabsArgument]?.stringValue { return max(1, list.split(separator: ",").count) }
        let id: String? = invocation.target.flatMap { $0.kind == .tab ? $0.id : nil }
            ?? services.windows.active?.focusedPane?.stripModel.selectedID?.rawValue
        guard let id, let (_, pane) = services.locateTab(id), let controller = services.paneController(for: pane) else { return 1 }
        return controller.stripModel.actionTabs(for: StripTabID(id)).count
    }
}
