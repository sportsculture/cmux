import Foundation

/// Titles of tab actions while they act on a multi-selection (menu rows and palette rows). Keys
/// live in Resources/TabSelection.xcstrings (all 21 app locales).
extension TabMultiSelection {
    /// New Tab Group on a multi-selection.
    public static var createGroupTitle: String {
        String(localized: "tabs.selection.createGroup", defaultValue: "Add Tabs to New Group", table: "TabSelection", bundle: .module)
    }
    /// Add Tab to Group on a multi-selection.
    public static var addToGroupTitle: String {
        String(localized: "tabs.selection.addToGroup", defaultValue: "Add Tabs to Group…", table: "TabSelection", bundle: .module)
    }
    /// Remove from Group on a multi-selection.
    public static var removeFromGroupTitle: String {
        String(localized: "tabs.selection.removeFromGroup", defaultValue: "Remove Tabs from Group", table: "TabSelection", bundle: .module)
    }
    /// Close Tab on a multi-selection.
    public static var closeTitle: String {
        String(localized: "tabs.selection.close", defaultValue: "Close Tabs", table: "TabSelection", bundle: .module)
    }
}
