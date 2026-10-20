import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextTabs
import Testing

private typealias StripTab = CmuxNextTabs.TabID

/// Tab multi-select in one pane (Lawrence 2026-10-19: "make sure you can shift-select tabs or
/// command-select tabs, group them into tabs, and it works in a single pane"). Chrome's rules:
/// Cmd-click toggles a tab, Shift-click selects the range from the anchor, Cmd-Shift-click adds
/// the range; the clicked tab shows. A plain press selects on mouse-down; a Cmd- or Shift-click
/// and a press on a tab of a multi-selection act on mouse-up so a drag can take the selection.
/// The selection is derived (`TabStripModel.selectedIDs`): a tab switch from anywhere else ends
/// it and a closed tab leaves it, with no cleanup code.
@MainActor @Suite(.serialized) struct TabMultiSelectTests {
    private static func model(_ count: Int = 6, selected: Int = 0) -> TabStripModel {
        let model = TabStripModel(tabs: (0..<count).map { TabItem(id: StripTab("t\($0)"), title: "Tab \($0)") }, selectedID: StripTab("t\(selected)"))
        // The App's answer to `.select`: the shown tab moves (the focus coordinator, here at once).
        model.intentHandler = { [weak model] in if case .select(let id) = $0 { model?.selectedID = id } }
        return model
    }

    private static func ids(_ raw: Int...) -> [StripTab] { raw.map { StripTab("t\($0)") } }

    // MARK: Selection model

    @Test func cmdClickAddsATabAndShowsIt() {
        let model = Self.model()
        model.apply(model.clickOutcome(on: StripTab("t2"), modifiers: .toggle))
        #expect(model.selectedIDs == Self.ids(0, 2))
        #expect(model.selectedID == StripTab("t2"), "the Cmd-clicked tab shows (Chrome)")
        model.apply(model.clickOutcome(on: StripTab("t4"), modifiers: .toggle))
        #expect(model.selectedIDs == Self.ids(0, 2, 4))
    }

    @Test func cmdClickOnASelectedTabRemovesItAndTheNearestSelectedTabShows() {
        let model = Self.model()
        model.apply(model.clickOutcome(on: StripTab("t2"), modifiers: .toggle))
        model.apply(model.clickOutcome(on: StripTab("t3"), modifiers: .toggle))
        model.apply(model.clickOutcome(on: StripTab("t3"), modifiers: .toggle))
        #expect(model.selectedIDs == Self.ids(0, 2))
        #expect(model.selectedID == StripTab("t2"))
        // The last selected tab stays selected.
        model.apply(model.clickOutcome(on: StripTab("t0"), modifiers: .toggle))
        model.apply(model.clickOutcome(on: StripTab("t2"), modifiers: .toggle))
        #expect(model.selectedIDs == Self.ids(2))
    }

    @Test func shiftClickSelectsTheRangeFromTheAnchorBothWays() {
        let model = Self.model(selected: 2)
        model.apply(model.clickOutcome(on: StripTab("t4"), modifiers: .range))
        #expect(model.selectedIDs == Self.ids(2, 3, 4))
        #expect(model.selectedID == StripTab("t4"))
        // The anchor stays at t2: Shift-click on t0 now selects t0...t2.
        model.apply(model.clickOutcome(on: StripTab("t0"), modifiers: .range))
        #expect(model.selectedIDs == Self.ids(0, 1, 2))
    }

    @Test func cmdShiftClickAddsTheRangeToTheSelection() {
        let model = Self.model()
        model.apply(model.clickOutcome(on: StripTab("t3"), modifiers: .toggle))
        model.apply(model.clickOutcome(on: StripTab("t5"), modifiers: [.toggle, .range]))
        #expect(model.selectedIDs == Self.ids(0, 3, 4, 5))
    }

    @Test func aPlainClickEndsTheSelection() {
        let model = Self.model()
        model.apply(model.clickOutcome(on: StripTab("t3"), modifiers: .range))
        #expect(model.hasMultiSelection)
        model.apply(model.clickOutcome(on: StripTab("t1"), modifiers: []))
        #expect(model.selectedIDs == Self.ids(1))
        #expect(model.multiSelection == nil)
    }

    @Test func aTabSwitchFromAnywhereElseEndsTheSelectionWithoutAnyoneClearingIt() {
        let model = Self.model()
        model.apply(model.clickOutcome(on: StripTab("t3"), modifiers: .range))
        // A shortcut, the palette, the CLI or an agent shows another tab.
        model.selectedID = StripTab("t5")
        #expect(model.selectedIDs == Self.ids(5))
        #expect(model.actionTabs(for: StripTab("t1")) == Self.ids(1))
    }

    @Test func aClosedTabLeavesTheSelection() {
        let model = Self.model()
        model.apply(model.clickOutcome(on: StripTab("t3"), modifiers: .range))
        model.tabs.removeAll { $0.id == StripTab("t1") }
        #expect(model.selectedIDs == Self.ids(0, 2, 3))
    }

    @Test func anActionOnATabOutsideTheSelectionActsOnThatTabAlone() {
        let model = Self.model()
        model.apply(model.clickOutcome(on: StripTab("t2"), modifiers: .range))
        #expect(model.actionTabs(for: StripTab("t1")) == Self.ids(0, 1, 2))
        #expect(model.actionTabs(for: StripTab("t4")) == Self.ids(4))
    }

    @Test func theLocalReducerMovesASelectionAsOneBlockIntoAGroup() {
        let model = Self.model()
        let group = TabGroupItem(id: TabGroupID("g"), name: "G", colorToken: .blue)
        model.groups = [group]
        model.tabs[4].groupID = group.id
        model.tabs[5].groupID = group.id
        // t0 and t2 dragged to the group's end: the rest is t1 t3 t4 t5, the block lands at rest index 4.
        #expect(model.apply(.moveTabs(Self.ids(2, 0), to: 4, membership: .join(group.id)), makeTab: { TabItem(id: StripTab("x"), title: "x") }))
        #expect(model.orderedTabs.map(\.id) == Self.ids(1, 3, 4, 5, 2, 0))
        #expect(model.members(of: group.id).map(\.id) == Self.ids(4, 5, 2, 0))
    }

    @Test(arguments: [
        // current order, block, step, rest index -> display index
        (["a", "b", "c", "d", "e"], ["b", "d"], 0, 3, 3),
        (["a", "c", "e", "b", "d"], ["b", "d"], 1, 3, 4),
        (["a", "b", "c", "d", "e"], ["d", "b"], 0, 0, 0),
        (["d", "a", "b", "c", "e"], ["d", "b"], 1, 0, 1),
        (["a", "b", "c"], ["a"], 0, 2, 2),
    ])
    func aBlockMoveStepGoesAfterThePreviousStep(_ input: ([String], [String], Int, Int, Int)) {
        #expect(TabMoveIndex.blockStepIndex(current: input.0, block: input.1, step: input.2, restIndex: input.3) == input.4)
    }

    // MARK: The strip's pointer rules

    private struct StripHarness {
        let model: TabStripModel
        let strip: TabStripView
        let window: NSWindow

        init() {
            model = TabMultiSelectTests.model(4)
            strip = TabStripView(model: model)
            strip.dragsWindowFromEmptySpace = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
            strip.frame = NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight)
            window.contentView = strip
            window.orderFrontRegardless()
            strip.layoutSubtreeIfNeeded()
        }

        func point(_ id: String, dx: CGFloat = 0) throws -> CGPoint {
            let cell = try #require(strip.cells[StripTab(id)])
            return strip.convert(strip.convert(CGPoint(x: cell.frame.midX + dx, y: cell.frame.midY), from: strip.tabsClip), to: nil)
        }

        func event(_ type: NSEvent.EventType, at point: CGPoint, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }

        func click(_ id: String, _ flags: NSEvent.ModifierFlags = []) throws {
            let at = try point(id)
            strip.mouseDown(with: try event(.leftMouseDown, at: at, flags))
            strip.mouseUp(with: try event(.leftMouseUp, at: at, flags))
            strip.syncFromModel()
        }
    }

    @Test func cmdAndShiftClicksSelectOnMouseUpAndDrawTheSelection() throws {
        let h = StripHarness()
        defer { h.window.orderOut(nil) }
        let at = try h.point("t2")
        h.strip.mouseDown(with: try h.event(.leftMouseDown, at: at, .command))
        #expect(h.model.selectedIDs == Self.ids(0), "a Cmd-click acted on the press (it must wait for a drag)")
        h.strip.mouseUp(with: try h.event(.leftMouseUp, at: at, .command))
        h.strip.syncFromModel()
        #expect(h.model.selectedIDs == Self.ids(0, 2))
        #expect(h.strip.cells[StripTab("t0")]?.isMultiSelected == true, "the other selected tab is not drawn selected")
        #expect(h.strip.cells[StripTab("t2")]?.isSelected == true)
        #expect(h.strip.cells[StripTab("t1")]?.isMultiSelected == false)
        try h.click("t3", .shift)
        #expect(h.model.selectedIDs == Self.ids(2, 3), "Shift-click selects from the anchor (the last Cmd-clicked tab)")
    }

    @Test func aPlainPressOnASelectedTabKeepsTheSelectionUntilTheRelease() throws {
        let h = StripHarness()
        defer { h.window.orderOut(nil) }
        try h.click("t2", .shift)
        #expect(h.model.selectedIDs == Self.ids(0, 1, 2))
        let at = try h.point("t1")
        h.strip.mouseDown(with: try h.event(.leftMouseDown, at: at))
        #expect(h.model.selectedIDs == Self.ids(0, 1, 2), "the press dropped the selection a drag needs")
        h.strip.mouseUp(with: try h.event(.leftMouseUp, at: at))
        #expect(h.model.selectedIDs == Self.ids(1), "a click without a drag selects that tab alone")
        // A plain press on an unselected tab still selects on mouse-down.
        try h.click("t3", .shift)
        let other = try h.point("t0")
        h.strip.mouseDown(with: try h.event(.leftMouseDown, at: other))
        #expect(h.model.selectedID == StripTab("t0"))
        #expect(h.model.selectedIDs == Self.ids(0))
        h.strip.mouseUp(with: try h.event(.leftMouseUp, at: other))
    }

    @Test func draggingASelectionMovesEveryTabAsOneBlock() throws {
        let h = StripHarness()
        defer { h.window.orderOut(nil) }
        try h.click("t1", .command)
        #expect(h.model.selectedIDs == Self.ids(0, 1))
        var sent: [TabStripIntent] = []
        let select = h.model.intentHandler
        h.model.intentHandler = { intent in sent.append(intent); select?(intent) }
        // Press t1 (selected) and drag it right past t3.
        let start = try h.point("t1")
        let end = try h.point("t3", dx: 40)
        h.strip.mouseDown(with: try h.event(.leftMouseDown, at: start))
        for step in 1...12 {
            let x = start.x + (end.x - start.x) * CGFloat(step) / 12
            h.strip.mouseDragged(with: try h.event(.leftMouseDragged, at: CGPoint(x: x, y: start.y)))
        }
        #expect(h.strip.cells[StripTab("t0")] == nil, "the other selected tab did not gather with the dragged one")
        h.strip.mouseUp(with: try h.event(.leftMouseUp, at: end))
        let moves = sent.compactMap { intent -> ([StripTab], Int)? in
            if case .moveTabs(let ids, let to, _) = intent { return (ids, to) }
            return nil
        }
        #expect(moves.count == 1, "sent \(sent)")
        #expect(moves.first?.0 == Self.ids(1, 0), "the dragged tab leads, its companion follows")
        #expect(moves.first?.1 == 2, "the block lands after t2 and t3")
        #expect(h.strip.presentedTabIDs == Self.ids(2, 3, 1, 0), "the strip does not show the block where it was dropped")
    }

    @Test func aRightClickInsideTheSelectionOffersTheWholeSelection() throws {
        let h = StripHarness()
        defer { h.window.orderOut(nil) }
        try h.click("t2", .shift)
        var targets: [TabContextTarget] = []
        h.strip.contextMenuProvider = { targets.append($0); return nil }
        _ = h.strip.menu(for: try h.event(.rightMouseDown, at: try h.point("t1")))
        _ = h.strip.menu(for: try h.event(.rightMouseDown, at: try h.point("t3")))
        #expect(targets == [.tab(StripTab("t1"), selection: Self.ids(0, 1, 2)), .tab(StripTab("t3"), selection: Self.ids(3))])
        #expect(h.model.selectedIDs == Self.ids(2), "a right-click outside the selection ends it (Chrome)")
    }
}
