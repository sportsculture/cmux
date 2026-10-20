import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextTabs
import Foundation
import Testing

/// Group, close and every other tab action act on the same tabs from the tab menu and from the
/// palette (Lawrence 2026-10-19: "right-click to make tab groups is broken but the Cmd-Shift-P
/// path works ... eliminate this entire error class"). Both run one registered action by one id;
/// the menu passes the right-clicked tab as the target, the palette the focused one, and the
/// action resolves the tabs it acts on in one place (`AppActionContext.actionTabs`): the tab and,
/// when it is in its strip's multi-selection, every selected tab. Runs against a same-tree
/// cmux-tui daemon, as the app does.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TabSelectionActionsTests {
    /// The window's one pane with `count` tabs, its strip synced.
    private static func pane(with count: Int, _ services: AppServices, _ connection: DaemonConnection) async throws -> PaneController {
        let pane = try #require(services.windows.active?.workspaceContent?.panes.values.first)
        for _ in pane.pane.tabs.count..<max(count, pane.pane.tabs.count) { _ = try await connection.newTab(in: pane.pane.handle) }
        try await PinnedPageTests.until({ pane.stripModel.tabs.count >= count }, report: { "\(pane.stripModel.tabs.map(\.id))" })
        return pane
    }

    /// Shift-clicks the strip's tabs `from` ... `to` (display indexes) as a person would, through the strip model.
    private static func select(_ range: ClosedRange<Int>, in pane: PaneController) async throws {
        let ids = pane.stripModel.orderedTabs.map(\.id)
        pane.stripModel.apply(pane.stripModel.clickOutcome(on: ids[range.lowerBound], modifiers: []))
        try await PinnedPageTests.until({ pane.stripModel.selectedID == ids[range.lowerBound] })
        pane.stripModel.apply(pane.stripModel.clickOutcome(on: ids[range.upperBound], modifiers: .range))
        try await PinnedPageTests.until({ pane.stripModel.selectedIDs == Array(ids[range]) },
                                        report: { "selected \(pane.stripModel.selectedIDs), shown \(String(describing: pane.stripModel.selectedID))" })
    }

    /// The tab menu row that runs `id`, wherever it sits (top level or a folder).
    private static func row(_ id: ActionID, in menu: NSMenu) -> NSMenuItem? {
        func all(_ items: [NSMenuItem]) -> [NSMenuItem] { items.flatMap { [$0] + ($0.submenu.map { all($0.items) } ?? []) } }
        return all(menu.items).first { ActionRegistry.menuRun(of: $0)?.id == id }
    }

    /// Clicks a context menu row: what `ActionMenuTarget.performAction` runs, with its refusal.
    private static func click(_ item: NSMenuItem, _ services: AppServices) -> String? {
        guard let run = ActionRegistry.menuRun(of: item) else { return "not an action row" }
        return services.registry.capturingRefusal {
            _ = services.registry.perform(run.id, invocation: ActionInvocation(target: run.target, arguments: run.arguments))
        }
    }

    private static func groups(of ids: [StripTabID], in pane: PaneController) -> Set<String?> {
        Set(ids.map { pane.tab($0)?.tabGroup?.rawValue })
    }

    @Test func theTabMenuGroupsEverySelectedTabInOneGroup() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try await Self.pane(with: 4, services, connection)
            try await Self.select(1...3, in: pane)
            let ids = Array(pane.stripModel.orderedTabs.map(\.id)[1...3])
            let menu = try #require(pane.contextMenu(for: .tab(ids[0], selection: pane.stripModel.actionTabs(for: ids[0]))))
            let row = try #require(Self.row("tabGroup.create", in: menu), "the tab menu has no New Tab Group row")
            #expect(row.title == TabMultiSelection.createGroupTitle, "the row does not say it groups the selected tabs")
            #expect(pane.stripModel.selectedIDs == ids, "the right-click dropped the selection")
            let refusal = Self.click(row, services)
            #expect(refusal == nil, "the tab menu's New Tab Group refused: \(refusal ?? "")")
            try await PinnedPageTests.until({ Self.groups(of: ids, in: pane).count == 1 && !Self.groups(of: ids, in: pane).contains(nil) },
                                            report: { "groups \(Self.groups(of: ids, in: pane)), refusal \(refusal ?? "none")" })
            #expect(pane.tab(pane.stripModel.orderedTabs[0].id)?.tabGroup == nil, "an unselected tab joined the group")
        }
    }

    @Test func thePaletteGroupsTheSameSelectedTabs() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try await Self.pane(with: 4, services, connection)
            try await Self.select(0...2, in: pane)
            let ids = Array(pane.stripModel.orderedTabs.map(\.id)[0...2])
            // The palette runs the action with no target: the focused pane's shown tab.
            #expect(services.registry.action(for: "tabGroup.create")?.paletteTitle?() == TabMultiSelection.createGroupTitle)
            let refusal = services.registry.capturingRefusal { _ = services.registry.perform("tabGroup.create", invocation: ActionInvocation()) }
            #expect(refusal == nil, "the palette's New Tab Group refused: \(refusal ?? "")")
            try await PinnedPageTests.until({ Self.groups(of: ids, in: pane).count == 1 && !Self.groups(of: ids, in: pane).contains(nil) },
                                            report: { "groups \(Self.groups(of: ids, in: pane)), refusal \(refusal ?? "none")" })
        }
    }

    @Test func closeOnASelectionClosesEverySelectedTab() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try await Self.pane(with: 4, services, connection)
            try await Self.select(1...2, in: pane)
            let all = pane.stripModel.orderedTabs.map(\.id), closing = Array(all[1...2])
            let menu = try #require(pane.contextMenu(for: .tab(closing[1], selection: pane.stripModel.actionTabs(for: closing[1]))))
            let row = try #require(Self.row("closeTab", in: menu))
            #expect(row.title == TabMultiSelection.closeTitle)
            #expect(Self.click(row, services) == nil)
            try await PinnedPageTests.until({ Set(pane.pane.tabs.map(\.id)) == Set([all[0], all[3]].map(\.rawValue)) },
                                            report: { "\(pane.pane.tabs.map(\.id))" })
        }
    }

    /// The bug class: every row of the tab menu can run exactly when the palette's run of the same
    /// action on the same (focused) tab can. A row that is enabled for one and refused or hidden
    /// for the other is a menu-only or palette-only path.
    @Test func everyTabMenuRowRunsLikeThePaletteOnTheSameTab() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try await Self.pane(with: 2, services, connection)
            let id = try #require(pane.stripModel.selectedID)
            let menu = try #require(pane.contextMenu(for: .tab(id, selection: [id])))
            func all(_ items: [NSMenuItem]) -> [NSMenuItem] { items.flatMap { [$0] + ($0.submenu.map { all($0.items) } ?? []) } }
            let runs = all(menu.items).compactMap(ActionRegistry.menuRun(of:))
            #expect(!runs.isEmpty)
            var diverged: [String] = []
            for run in runs {
                #expect(services.registry.isBound(run.id), "\(run.id) is a menu row with no registered handler")
                #expect(run.target == ActionTargetRef(kind: .tab, id: id.rawValue), "\(run.id) targets \(String(describing: run.target))")
                let menuOK = ActionTargetReasons.canPerform(run.id, invocation: ActionInvocation(target: run.target, arguments: run.arguments), in: services.registry)
                let paletteOK = ActionTargetReasons.canPerform(run.id, invocation: ActionInvocation(arguments: run.arguments), in: services.registry)
                if menuOK != paletteOK { diverged.append("\(run.id) menu=\(menuOK) palette=\(paletteOK)") }
            }
            #expect(diverged.isEmpty, "rows that run differently from the menu and the palette: \(diverged)")
        }
    }
}
