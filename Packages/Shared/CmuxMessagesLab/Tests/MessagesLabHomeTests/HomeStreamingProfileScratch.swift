import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Scratch profile (not for landing): where a streaming frame's main-thread time goes. `sample`
/// watches this process while a long reply streams; the main thread's heaviest frames print as
/// HOMEPROFILE lines, and each action's commits print their count and time.
@MainActor @Suite(.serialized) struct HomeStreamingProfileScratch {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    @Test func profileALongStream() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("home-stream-prof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: dir.appendingPathComponent("blobs"))
        store.start()
        defer { store.stop() }
        for _ in 0..<20_000 where !(store.me != nil && store.isOnline) { await Task.yield() }
        let conv = ConversationID("conv_chief")
        await store.open(conv)
        for _ in 0..<20_000 where store.transcript(for: conv).isEmpty { await Task.yield() }
        let me = try #require(store.me?.id)
        let chief = try #require(store.transcript(for: conv).first { $0.author != me }?.author)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = MessagesLabHomeView(store: store, conversation: conv, me: me, wake: NoWake())
        defer { view.stop() }
        view.frame = NSRect(x: 0, y: 0, width: 760, height: 900)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        var pending: [() -> Void] = []
        view.controller.nextFrame = { pending.append($0) }
        let tokens = HomeStreamingPerfTests.replyTokens(count: 5000)
        var draft = HomeTurnDraft(participant: chief, turn: IdempotencyKey("turn_prof"))
        var text = ""
        var labels: [String: (n: Int, ms: Double)] = [:]
        var sampler: Process?
        let out = dir.appendingPathComponent("sample.txt")
        var bands: [(Int, Double)] = []
        var t0 = CACurrentMediaTime()
        for (i, tok) in tokens.enumerated() {
            if i == 2500 {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                p.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "4", "1", "-mayDie", "-file", out.path]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                sampler = p
            }
            if i % 2 == 0 {
                let w = pending; pending.removeAll(); for f in w { f() }
            }
            text += tok
            draft.segments[0] = text
            draft.lastSeq = UInt64(i + 1)
            MessagesWindowView.commitLog = []
            store.drafts[conv] = draft
            view.projection.refresh()
            if i % 2 == 1 { window.contentView?.layoutSubtreeIfNeeded(); CATransaction.flush() }
            for entry in MessagesWindowView.commitLog ?? [] where !entry.hasPrefix(" ") {
                let f = entry.split(separator: " ")
                guard f.count > 1, let v = Double(f[1]) else { continue }
                let k = String(f[0]) + (i < 1500 ? " <8KB" : " long")
                labels[k, default: (0, 0)].n += 1
                labels[k, default: (0, 0)].ms += v
            }
            if i % 500 == 499 { bands.append((text.utf8.count, (CACurrentMediaTime() - t0) * 1000 / 250)); t0 = CACurrentMediaTime() }
            await Task.yield()
        }
        MessagesWindowView.commitLog = nil
        for (bytes, ms) in bands { print(String(format: "HOMEPROFILE bytes %d frame mean %.2f ms", bytes, ms)) }
        for (k, v) in labels.sorted(by: { $0.value.ms > $1.value.ms }) { print(String(format: "HOMEPROFILE commit %@ n %d total %.1f ms", k, v.n, v.ms)) }
        // Where the long-text frames go: the stream row's spec equality and its measurement, alone.
        if let st = view.controller.store?.state, let s = st.ui.streams.first {
            let m = s.message
            var m2 = m
            if case let .text(t, runs) = m.parts.first { m2.parts = [.text(t + " more", runs: runs)] }
            var a = CACurrentMediaTime()
            _ = MeasureCache.shared.size(m2, 0, width: view.controller.demo?.bounds.width ?? 760)
            print(String(format: "HOMEPROFILE measure one extended long text %.2f ms", (CACurrentMediaTime() - a) * 1000))
            a = CACurrentMediaTime()
            let same = m.parts == m2.parts
            print(String(format: "HOMEPROFILE parts == (differ at end) %.2f ms %d", (CACurrentMediaTime() - a) * 1000, same ? 1 : 0))
            var copy = view.projection.core
            draft.segments[0] = text + " more words"
            a = CACurrentMediaTime()
            _ = copy.stream(draft, state: st)
            print(String(format: "HOMEPROFILE map stream bubble %.2f ms", (CACurrentMediaTime() - a) * 1000))
        }
        sampler?.waitUntilExit()
        guard let report = try? String(contentsOf: out, encoding: .utf8) else { print("HOMEPROFILE no sample output"); return }
        // The call tree's main thread, then the top-of-stack summary.
        var inMain = false, printed = 0, total = 0
        for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains("Thread_") && line.contains("com.apple.main-thread") { inMain = true }
            else if inMain && line.contains("Thread_") { inMain = false }
            guard inMain, printed < 500 else { continue }
            let body = line.drop { " +!:|".contains($0) }
            guard let n = Int(body.prefix { $0.isNumber }) else { continue }
            if total == 0 { total = n }
            if n * 50 >= total {
                let depth = line.count - body.count
                print("HOMEPROFILE \(depth) \(body.prefix(200))")
                printed += 1
            }
        }
        if let r = report.range(of: "Sort by top of stack") {
            for line in report[r.lowerBound...].split(separator: "\n").prefix(60) { print("HOMEPROFILE top \(line.prefix(200))") }
        }
    }
}
