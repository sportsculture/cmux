import AppKit
@testable import CmuxNextApp
@testable import CmuxNextHome
import CmuxHomeCore
@testable import MessagesLabSidebar
import Testing

/// Lawrence 2026-10-19 (u2611): "After clicking on one of the things in home (like I click on the
/// profile), I want us to be focused on the text input area directly. Specifically the text input
/// area for sending messages."
///
/// Opening a conversation from Home's list (a click on its row or pinned tile, the one already
/// open too, Return on the highlighted one) leaves the keyboard in that conversation's message
/// box, as Messages does, also when the box only exists once the conversation's first page is in.
/// Up/Down in the list keep the list's keyboard (the person is still moving), and Command- or
/// Shift-click keep the click's old effect (the highlight only).
///
/// The clicks run as AppKit runs them: a left mouse-down on the list's document view at the
/// item's place, with its mouse-up queued for the list's press-and-drag loop.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct HomeOpenFocusesComposerTests {
    struct Harness {
        let services: AppServices
        let window: NSWindow
        let page: TopHomePageView

        var document: NSView { page.list.list.controller.document }

        /// The shown conversation's message box, once its first page installed it.
        var box: NSTextView? { page.host?.focusTarget as? NSTextView }

        /// A plain (or modified) click on the list item `id`, mouse-down then mouse-up in place.
        func click(_ id: String, modifiers: NSEvent.ModifierFlags = []) throws {
            let item = try #require(page.list.itemFramesInWindow.first { $0.id.rawValue == id }, "no list item \(id)")
            let height = window.contentView?.bounds.height ?? 0
            let point = NSPoint(x: item.frame.midX, y: height - item.frame.midY)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            NSApp.postEvent(try event(.leftMouseUp), atStart: false)
            document.mouseDown(with: try event(.leftMouseDown))
            // A list that did not track the press leaves its mouse-up queued: drop it.
            while NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) != nil {}
        }

        /// A key-down on the list's document view (`keyCode` for arrows, `characters` for Return).
        func key(_ keyCode: UInt16, _ characters: String) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                      isARepeat: false, keyCode: keyCode))
            document.keyDown(with: event)
        }

        func close() { window.orderOut(nil) }
    }

    static let rows = ["conv_open_focus_a", "conv_open_focus_b", "conv_open_focus_c"]
    static let pinned = "conv_open_focus_pin"

    private static func wait(_ limit: Duration = .seconds(10), until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        // Polls a condition the app reaches on its own turns (the first page installing the box).
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Home's two columns in a window: a pinned tile and three rows, `rows[0]` shown with its box in.
    private static func harness() async throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let page = TopHomePageView(services: services, windowKey: { "open-focus" })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        page.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        window.contentView = page
        window.orderFrontRegardless()
        let now = Date()
        let entries = ([pinned] + rows).enumerated().map { index, id in
            CmuxSidebarEntry(id: id, title: id, people: [CmuxSidebarEntry.Person(id: "p\(index)", name: id, initials: "P")],
                             preview: "hi", previewSender: nil, lastAt: now.addingTimeInterval(-Double(index) * 60),
                             unreadCount: 0, pinned: id == pinned)
        }
        // The page's own (empty, offline) inbox model lands on its first turns; the list then shows these items.
        for _ in 0..<50 { await Task.yield() }
        page.list.list.show(entries, pinned: [pinned])
        page.layoutSubtreeIfNeeded()
        page.show(ConversationID(rows[0]))
        let h = Harness(services: services, window: window, page: page)
        await wait { h.box != nil }
        _ = try #require(h.box, "Home's message box never appeared")
        try #require(page.list.itemFramesInWindow.count == entries.count, "the list does not show the test items")
        return h
    }

    /// The keyboard sat on the list (the person used it last), as before any click on it.
    private static func keyboardOnList(_ h: Harness) {
        h.window.makeFirstResponder(h.document)
    }

    @Test func clickingAConversationRowPutsTheKeyboardInItsMessageBox() async throws {
        let h = try await Self.harness()
        defer { h.close() }
        Self.keyboardOnList(h)
        try h.click(Self.rows[1])
        #expect(h.page.shown?.rawValue == Self.rows[1])
        await Self.wait { h.box != nil && h.window.firstResponder === h.box }
        #expect(h.window.firstResponder === h.box, "the click left the keyboard on \(String(describing: h.window.firstResponder))")
    }

    @Test func clickingAPinnedContactPutsTheKeyboardInItsMessageBox() async throws {
        let h = try await Self.harness()
        defer { h.close() }
        Self.keyboardOnList(h)
        try h.click(Self.pinned)
        #expect(h.page.shown?.rawValue == Self.pinned)
        await Self.wait { h.box != nil && h.window.firstResponder === h.box }
        #expect(h.window.firstResponder === h.box, "the click left the keyboard on \(String(describing: h.window.firstResponder))")
    }

    @Test func clickingTheConversationAlreadyOpenTakesTheKeyboardBackToItsBox() async throws {
        let h = try await Self.harness()
        defer { h.close() }
        let box = try #require(h.box)
        Self.keyboardOnList(h)
        try h.click(Self.rows[0])
        #expect(h.page.shown?.rawValue == Self.rows[0])
        #expect(h.page.host?.focusTarget === box, "reopening the shown conversation made a new transcript")
        #expect(h.window.firstResponder === box, "the click left the keyboard on \(String(describing: h.window.firstResponder))")
    }

    @Test func returnOnTheHighlightedConversationOpensItInItsBoxAndArrowsKeepTheList() async throws {
        let h = try await Self.harness()
        defer { h.close() }
        Self.keyboardOnList(h)
        try h.key(125, String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)))
        #expect(h.page.shown?.rawValue == Self.rows[1], "Down did not move to the next conversation")
        #expect(h.window.firstResponder === h.document, "Down moved the keyboard out of the list")
        try h.key(36, "\r")
        await Self.wait { h.box != nil && h.window.firstResponder === h.box }
        #expect(h.window.firstResponder === h.box, "Return left the keyboard on \(String(describing: h.window.firstResponder))")
    }

    @Test(arguments: [NSEvent.ModifierFlags.command, .shift])
    func aModifiedClickKeepsTheKeyboardWhereItWas(_ modifier: NSEvent.ModifierFlags) async throws {
        let h = try await Self.harness()
        defer { h.close() }
        Self.keyboardOnList(h)
        try h.click(Self.rows[2], modifiers: modifier)
        // The click still shows the conversation (its old effect); wait until its box is in.
        await Self.wait { h.page.shown?.rawValue == Self.rows[2] && h.box != nil }
        #expect(h.box != nil)
        #expect(h.window.firstResponder === h.document, "a \(modifier) click moved the keyboard")
    }
}
