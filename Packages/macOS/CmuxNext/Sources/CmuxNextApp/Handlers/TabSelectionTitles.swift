import CmuxNextActions
import CmuxNextTabs

/// The tab actions that act on a whole multi-selection read so in the tab menu and the palette
/// ("Add Tabs to New Group" over "New Tab Group") while more than one tab is selected.
struct TabSelectionTitles {
    let context: AppActionContext

    /// The multi-selection title of each selection-aware tab action.
    static let titles: [ActionID: () -> String] = [
        "tabGroup.create": { TabMultiSelection.createGroupTitle },
        "tabGroup.addTab": { TabMultiSelection.addToGroupTitle },
        "tabGroup.removeTab": { TabMultiSelection.removeFromGroupTitle },
        "closeTab": { TabMultiSelection.closeTitle },
    ]

    /// Sets each action's menu and palette title; call after the actions are bound.
    @MainActor func install(in registry: ActionRegistry) {
        for (id, title) in Self.titles {
            ActionTargetTitles.set(id, in: registry) { context.actionTabCount($0) > 1 ? title() : nil }
            ActionTargetTitles.setPaletteTitle(id, in: registry) { context.actionTabCount(ActionInvocation()) > 1 ? title() : nil }
        }
    }
}
