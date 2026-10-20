import AppKit

struct TabStripPress {
    var id: TabID
    var start: CGPoint
    /// The click this press makes on mouse-up when no drag starts (the Finder rule): a Cmd- or
    /// Shift-click, or a plain press on a tab of a multi-selection, which must keep the selection
    /// for a drag. Nil when the press already selected on mouse-down.
    var deferredClick: TabClickModifiers?
}

struct TabStripDrag {
    var id: TabID
    var grabOffset: CGFloat
    var originalIndex: Int
    var currentIndex: Int
    var isPinned: Bool
    var lastPoint: CGPoint
    var originalGroup: TabGroupID?
    var targetGroup: TabGroupID?
    var grabY: CGFloat = 0 // press y in the clip; with grabOffset, the grabbed point the hand-off keeps
    /// Pointer x (content coordinates) at the last reorder: the next one waits until the pointer has
    /// moved the reorder threshold from here (Chrome's kHorizontalMoveThreshold, against jitter).
    var lastMoveX: CGFloat = 0
    /// The other selected tabs moving with this one, in display order (a multi-selection drag).
    var companions: [TabID] = []
}
