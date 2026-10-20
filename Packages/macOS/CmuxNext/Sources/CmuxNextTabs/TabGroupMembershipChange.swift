/// What a move does to the moved tabs' group (`TabStripIntent.moveTabs`).
public enum TabGroupMembershipChange: Hashable, Sendable {
    /// Each tab keeps its group.
    case keep
    /// Every moved tab joins the group.
    case join(TabGroupID)
    /// Every moved tab leaves its group.
    case leave
}
