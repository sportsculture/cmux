/// Tabs selected together with a strip's shown tab (Chrome's `ListSelectionModel`): Cmd-click
/// toggles a tab, Shift-click selects the range from the anchor. Group, close and drag act on
/// every selected tab.
///
/// The strip's selection has one source of truth: ``TabStripModel/selectedIDs`` is derived from
/// this value and the model's `selectedID` and `tabs` every time it is read. A multi-selection
/// counts only while the strip still shows its ``active`` tab, so a tab switch from anywhere
/// else (a shortcut, the palette, the CLI, an agent) ends it without anyone clearing it, and a
/// closed tab leaves it without a cleanup pass. No stored state can name a tab the strip lost
/// or keep a second "selected" tab the App does not show.
public struct TabMultiSelection: Hashable, Sendable {
    /// The tab the selection was made around. It must be the model's `selectedID` for the
    /// selection to count.
    public let active: TabID
    /// The other selected tabs. Never contains ``active``.
    public let others: Set<TabID>
    /// Where the next Shift-click range starts.
    public let anchor: TabID

    /// - Parameters:
    ///   - active: The shown tab.
    ///   - others: Tabs selected with it; `active` is removed if listed.
    ///   - anchor: The Shift-click range start; `active` when nil.
    public init(active: TabID, others: Set<TabID>, anchor: TabID? = nil) {
        self.active = active
        self.others = others.subtracting([active])
        self.anchor = anchor ?? active
    }

    /// Every selected tab, `active` included.
    public var all: Set<TabID> { others.union([active]) }
}
