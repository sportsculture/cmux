/// What a click on a tab does to a strip's selection.
public struct TabClickOutcome: Hashable, Sendable {
    /// The tab to show (`TabStripIntent.select`); nil leaves the shown tab.
    public let select: TabID?
    /// The multi-selection after the click; nil for a single selected tab.
    public let selection: TabMultiSelection?
}
