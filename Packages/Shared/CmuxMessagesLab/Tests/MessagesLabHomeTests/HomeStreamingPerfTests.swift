import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Home stays smooth while the Chief's reply streams (Lawrence 2026-10-20: "When
/// it is streaming it is very laggy to do anything in general"). The real view
/// (`MessagesLabHomeView`) over a real `HomeStore` on the mock owner, in an
/// offscreen window. A long Markdown reply (headings, lists, code blocks, a
/// table; about 5k tokens) streams at two tokens per display frame (about
/// 100 tokens/s at 60 Hz) while the person types in the message box, then while
/// they scroll the transcript.
///
/// Each frame runs what the main thread runs for it: the store's change, the
/// projection's refresh (`HomeProjection.refresh`, as its observation does),
/// one layout pass and a Core Animation flush, then the input event.
///
/// The rules (plans/cmux-next/home-streaming-perf-DESIGN.md):
/// - a frame's streaming work stays far inside one 60 Hz frame (p95, p99, worst);
/// - the cost of a token follows the token, not the reply's length so far
///   (the last 500 tokens cost about what the first 500 did);
/// - a keystroke or a scroll step costs about what it costs with no stream.
///
/// `HOMESTREAM` lines in the log carry the numbers.
@MainActor @Suite(.serialized) struct HomeStreamingPerfTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    private static func ms(_ t0: CFTimeInterval) -> Double { (CACurrentMediaTime() - t0) * 1000 }
    static func p(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))]
    }
    private static func line(_ name: String, _ xs: [Double]) -> String {
        String(format: "%@ n %d p50 %.3f p95 %.3f p99 %.3f max %.2f ms", name, xs.count, p(xs, 0.5), p(xs, 0.95), p(xs, 0.99), xs.max() ?? 0)
    }

    /// A Chief-shaped Markdown reply, as tokens (about 4 characters each, spaces and newlines kept).
    static func replyTokens(count: Int) -> [String] {
        var tokens: [String] = []
        var section = 0
        func words(_ s: String) { for w in s.split(separator: " ", omittingEmptySubsequences: false) { tokens.append(String(w) + " ") } }
        while tokens.count < count {
            section += 1
            tokens.append("## Step \(section): rebuild the branch\n\n")
            words("Here is the plan for step \(section). Rebase on **origin/feat-cmux-next**, run the suites on the fleet, then push and report the `sha` of each commit. The `HomeProjection` path stays as it is.")
            tokens.append("\n\n")
            for i in 1...4 { tokens.append("- "); words("item \(i): check `cmux-ci wait` and read the *log* for step \(section)"); tokens.append("\n") }
            tokens.append("\n```swift\n")
            for i in 0..<12 { tokens.append("let value\(i) = try await fleet.run(step: \(section), shard: \(i)) // keep going\n") }
            tokens.append("```\n\n")
            tokens.append("| Suite | Result | Time |\n|---|---|---|\n")
            for i in 0..<5 { tokens.append("| Suite\(i) "); tokens.append("| passed "); tokens.append("| \(i * 3 + section) s |\n") }
            tokens.append("\n")
            words("That is all for step \(section); the next one follows after the fleet run is green and the report is written.")
            tokens.append("\n\n")
        }
        return Array(tokens.prefix(count))
    }

    /// A trackpad scroll step (continuous, pixel deltas), as AppKit delivers it to the scroll view.
    private static func scrollEvent(dy: Int32) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        return NSEvent(cgEvent: cg)
    }

    struct Frames {
        var token: [Double] = [], layout: [Double] = [], frame: [Double] = [], input: [Double] = []
    }

    @Test func aLongMarkdownReplyStreamsWithoutLag() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("home-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: dir.appendingPathComponent("blobs"))
        store.start()
        defer { store.stop() }
        await until { store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        let chief = try #require(store.transcript(for: Self.conversation).first { $0.author != me }?.author)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake())
        defer { view.stop() }
        view.frame = NSRect(x: 0, y: 0, width: 760, height: 900)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let projection = view.projection
        let field = try #require(view.controller.demo?.compose.textView.view)
        let scrollView = view.controller.host.scrollView
        window.makeFirstResponder(field)

        func flush() {
            window.contentView?.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }
        var typed = 0
        func key() -> Double {
            let k0 = CACurrentMediaTime()
            if typed % 40 == 39 {
                field.selectAll(nil)
                field.insertText("a", replacementRange: field.selectedRange())
            } else {
                field.insertText(typed % 6 == 5 ? " " : "e", replacementRange: field.selectedRange())
            }
            typed += 1
            flush()
            return Self.ms(k0)
        }
        var scrolls = 0
        let canScroll = Self.scrollEvent(dy: -4) != nil
        func scroll() -> Double {
            // Up 60 steps, down 60 steps, so the stream never pins the view back.
            let dy: Int32 = (scrolls / 60) % 2 == 0 ? 6 : -6
            scrolls += 1
            guard let e = Self.scrollEvent(dy: dy) else { return 0 }
            let s0 = CACurrentMediaTime()
            scrollView.scrollWheel(with: e)
            flush()
            return Self.ms(s0)
        }

        // No stream: the same input, for the baseline.
        var idleKey: [Double] = [], idleScroll: [Double] = []
        for _ in 0..<200 { idleKey.append(key()) }
        for _ in 0..<240 { idleScroll.append(scroll()) }
        // Back at the newest row for the stream's typing phase.
        view.controller.demo?.pinToBottom()
        flush()

        let tokens = Self.replyTokens(count: 5000)
        let turn = IdempotencyKey("turn_home_stream_perf")
        var draft = HomeTurnDraft(participant: chief, turn: turn)
        var text = ""
        let parses0 = (MarkdownStore.shared.fullParses, MarkdownStore.shared.tailParses)
        let misses0 = MeasureCache.shared.misses
        let created0 = RowCell.created
        let passes0 = MessagesWindowView.widthPasses
        MessagesWindowView.commitLog = []
        defer { MessagesWindowView.commitLog = nil }
        var commitPhases: [String: Double] = [:]
        var typing = Frames(), scrolling = Frames()
        var commits = 0
        let perFrame = 2
        var i = 0
        while i < tokens.count {
            for t in tokens[i..<min(tokens.count, i + perFrame)] { text += t }
            i += perFrame
            draft.segments[0] = text
            draft.lastSeq = UInt64(i)
            MessagesWindowView.commitLog = []
            let f0 = CACurrentMediaTime()
            store.drafts[Self.conversation] = draft
            projection.refresh()
            let tokenMs = Self.ms(f0)
            let l0 = CACurrentMediaTime()
            flush()
            let layoutMs = Self.ms(l0)
            let frameMs = Self.ms(f0)
            for entry in MessagesWindowView.commitLog ?? [] {
                commits += 1
                if let open = entry.firstIndex(of: "[") {
                    for kv in entry[entry.index(after: open)...].split(separator: ",") {
                        let parts = kv.split(separator: ":")
                        guard parts.count == 2 else { continue }
                        let k = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " \"[]"))
                        let v = Double(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " ]"))) ?? 0
                        commitPhases[k, default: 0] += v
                    }
                }
            }
            // The first half: typing in the message box; the second: scrolling the transcript.
            let typingPhase = i <= tokens.count / 2 || !canScroll
            let inputMs = typingPhase ? key() : scroll()
            if typingPhase {
                typing.token.append(tokenMs); typing.layout.append(layoutMs); typing.frame.append(frameMs); typing.input.append(inputMs)
            } else {
                scrolling.token.append(tokenMs); scrolling.layout.append(layoutMs); scrolling.frame.append(frameMs); scrolling.input.append(inputMs)
            }
            // The store's own observation refresh (a no-op: nothing changed since).
            await Task.yield()
        }
        let frames = typing.frame + scrolling.frame
        let label = "tokens=\(tokens.count) bytes=\(text.utf8.count) rows=\(projection.shown.count)"
        print("HOMESTREAM \(label) \(Self.line("frame (token + layout)", frames))")
        print("HOMESTREAM \(label) typing \(Self.line("token", typing.token))")
        print("HOMESTREAM \(label) typing \(Self.line("layout", typing.layout))")
        print("HOMESTREAM \(label) typing \(Self.line("keystroke", typing.input))")
        print("HOMESTREAM \(label) idle \(Self.line("keystroke", idleKey))")
        print("HOMESTREAM \(label) scrolling \(Self.line("token", scrolling.token))")
        print("HOMESTREAM \(label) scrolling \(Self.line("layout", scrolling.layout))")
        print("HOMESTREAM \(label) scrolling \(Self.line("scroll", scrolling.input))")
        print("HOMESTREAM \(label) idle \(Self.line("scroll", idleScroll)) canScroll \(canScroll)")
        let n = frames.count
        for b in stride(from: 0, to: n, by: 250) {
            print("HOMESTREAM \(label) frames \(b)..<\(min(n, b + 250)) \(Self.line("frame", Array(frames[b..<min(n, b + 250)])))")
        }
        for (k, v) in commitPhases.sorted(by: { $0.value > $1.value }).prefix(12) {
            print(String(format: "HOMESTREAM %@ commit phase %@ total %.1f ms", label, k, v))
        }
        let fullParses = MarkdownStore.shared.fullParses - parses0.0, tailParses = MarkdownStore.shared.tailParses - parses0.1
        let misses = MeasureCache.shared.misses - misses0
        print("HOMESTREAM \(label) commits \(commits) markdown full \(fullParses) tail \(tailParses) measureMisses \(misses) cellsCreated \(RowCell.created - created0) widthPasses \(MessagesWindowView.widthPasses - passes0)")

        let head = Array(frames.prefix(250)), tail = Array(frames.suffix(250))
        #expect(Self.p(frames, 0.95) < 4, "streaming frame p95 \(Self.p(frames, 0.95)) ms")
        #expect(Self.p(frames, 0.99) < 8, "streaming frame p99 \(Self.p(frames, 0.99)) ms")
        #expect((frames.max() ?? 0) < 16, "worst streaming frame \(frames.max() ?? 0) ms")
        #expect(Self.p(tail, 0.5) < 2 * Self.p(head, 0.5) + 0.5,
                "a token at the end of the reply costs \(Self.p(tail, 0.5)) ms p50, at the start \(Self.p(head, 0.5)) ms")
        #expect(Self.p(typing.input, 0.95) < Self.p(idleKey, 0.95) + 1,
                "a keystroke while streaming p95 \(Self.p(typing.input, 0.95)) ms, idle \(Self.p(idleKey, 0.95)) ms")
        if canScroll {
            #expect(Self.p(scrolling.input, 0.95) < Self.p(idleScroll, 0.95) + 1,
                    "a scroll step while streaming p95 \(Self.p(scrolling.input, 0.95)) ms, idle \(Self.p(idleScroll, 0.95)) ms")
        }
    }
}
