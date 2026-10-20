// ax-tour: a computer-use tour of a tagged cmux-next debug app, driven ONLY through the macOS
// accessibility API (AXUIElement reads and AXPress) plus window screenshots, the way OpenAI
// computer use or cmux-cua sees the app. It proves that an agent can find every step's control by
// its stable `cmux.<area>.<control>` identifier and that each step's result shows in the AX tree.
//
//   ax-tour --bundle-id com.cmuxterm.app.debug.<tag> [--out DIR] [--steps a,b,...] [--dump]
//
// Built and run by scripts/cmux-next/ax-tour.sh (swiftc). Safety: it acts only on a running app
// whose bundle id is a tagged debug build (`com.cmuxterm.app.debug.<tag>`); it refuses every other
// bundle id (the user's cmux, NIGHTLY, RC, an untagged DEV) before it reads anything. It never
// activates or focuses an app, never posts mouse or key events, and never quits or launches one.
//
// Steps (default: all, in order):
//   new-workspace   press cmux.sidebar.newWorkspace; a new cmux.sidebar.workspace.* row appears
//   new-tab         press cmux.tabs.newTab; the window has one more cmux.tabs.tab.* element
//   split-pane      press the menu item cmux.action.splitRight; one more cmux.pane.divider.* splitter
//   switch-tab      press an unselected cmux.tabs.tab.*; its AXValue becomes 1
//   palette         press cmux.action.commandPalette; cmux.commandPalette shows; press again to close
//   settings        press cmux.action.openSettings; a new window appears; its close button closes it
//   close-split     press cmux.action.closePane; the splitter count returns to its start
//   close-tab       press the new tab's cmux.tabs.tab.<id>.close; the tab count returns to its start
//   close-workspace press cmux.action.closeWorkspace; the workspace count returns to its start
//
// Output: DIR/manifest.json (each step: pass/fail, detail, screenshot) and DIR/shots/NN-step.png.
// Exit 0 when every step passes, 1 when one fails, 2 on a refused target or a missing grant.
import AppKit
import ApplicationServices
import ScreenCaptureKit

// MARK: Arguments and the target guard

struct Options {
    var bundleID = ""
    var out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ax-tour-\(getpid())")
    var steps: [String] = []
    var dump = false
    var settle: TimeInterval = 8
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("ax-tour: \(message)\n".utf8))
    exit(code)
}

func parse() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--bundle-id": options.bundleID = args.next() ?? ""
        case "--out": options.out = URL(fileURLWithPath: args.next() ?? "")
        case "--steps": options.steps = (args.next() ?? "").split(separator: ",").map(String.init)
        case "--settle": options.settle = TimeInterval(args.next() ?? "") ?? options.settle
        case "--dump": options.dump = true
        default: fail("unknown argument \(arg)", code: 2)
        }
    }
    return options
}

/// Only a tagged debug build: `com.cmuxterm.app.debug.<tag>`. The user's cmux, NIGHTLY, RC, a
/// release and an untagged DEV build share no prefix with it beyond `com.cmuxterm.app`.
func isTaggedDebugBundle(_ id: String) -> Bool {
    let prefix = "com.cmuxterm.app.debug."
    guard id.hasPrefix(prefix) else { return false }
    let tag = id.dropFirst(prefix.count)
    return !tag.isEmpty && tag.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
}

// MARK: AX reads (no writes except AXPress on the target app)

final class AX {
    let app: AXUIElement
    let pid: pid_t

    init(pid: pid_t) {
        self.pid = pid
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 5)
    }

    func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    func string(_ element: AXUIElement, _ name: String) -> String { (attr(element, name) as? String) ?? "" }

    func children(_ element: AXUIElement) -> [AXUIElement] { (attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

    var windows: [AXUIElement] { (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }

    /// Every element under the app's windows (web content is not walked: it is the page's own tree).
    func elements(under roots: [AXUIElement]? = nil, limit: Int = 20_000) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var stack = roots ?? windows
        while let element = stack.popLast(), out.count < limit {
            out.append(element)
            if string(element, kAXRoleAttribute) == "AXWebArea" { continue }
            stack.append(contentsOf: children(element).reversed())
        }
        return out
    }

    func identified(_ prefix: String, in roots: [AXUIElement]? = nil) -> [AXUIElement] {
        elements(under: roots).filter { string($0, kAXIdentifierAttribute).hasPrefix(prefix) }
    }

    /// A menu bar item by identifier (`cmux.action.<id>`); menus are walked closed, nothing opens.
    func menuItem(_ identifier: String) -> AXUIElement? {
        guard let bar = attr(app, kAXMenuBarAttribute) else { return nil }
        // swiftlint:disable:next force_cast
        return elements(under: [bar as! AXUIElement]).first { string($0, kAXIdentifierAttribute) == identifier }
    }

    @discardableResult
    func press(_ element: AXUIElement) -> AXError { AXUIElementPerformAction(element, kAXPressAction as CFString) }

    func value(_ element: AXUIElement) -> Int? { (attr(element, kAXValueAttribute) as? NSNumber)?.intValue }

    /// A printable line for one element (the `--dump` output).
    func describe(_ element: AXUIElement) -> String {
        [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute]
            .map { string(element, $0) }.joined(separator: " | ")
    }
}

/// Waits for a condition the app reaches on its own (an AX read each 100 ms, bounded by `timeout`).
/// A tour is an external observer with no event stream from the app, so a bounded poll is its signal.
func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return condition()
}

// MARK: Screenshots of the app's own windows

func screenshot(pid: pid_t, to url: URL) -> String? {
    let semaphore = DispatchSemaphore(value: 0)
    var problem: String?
    Task {
        defer { semaphore.signal() }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                problem = "no on-screen window of pid \(pid)"
                return
            }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * 2)
            configuration.height = Int(window.frame.height * 2)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                   configuration: configuration)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: url)
        } catch {
            problem = "ScreenCaptureKit: \(error.localizedDescription) (Screen Recording grant?)"
        }
    }
    semaphore.wait()
    return problem
}

// MARK: The tour

struct StepResult: Codable {
    let step: String
    let ok: Bool
    let detail: String
    let screenshot: String?
}

final class Tour {
    let ax: AX
    let options: Options
    var results: [StepResult] = []
    // What the tour created, so the closing steps remove only that.
    var startWorkspaces = Set<String>()
    var startTabs = Set<String>()
    var startDividers = 0
    var newTabID: String?

    init(ax: AX, options: Options) {
        self.ax = ax
        self.options = options
    }

    /// Identifiers under `prefix` of elements with `role` (a row's or a tab's own buttons have other roles).
    func ids(_ prefix: String, role: String) -> Set<String> {
        Set(ax.identified(prefix).filter { ax.string($0, kAXRoleAttribute) == role }.map { ax.string($0, kAXIdentifierAttribute) })
    }

    var workspaces: Set<String> { ids("cmux.sidebar.workspace.", role: "AXRow") }
    var tabs: Set<String> { ids("cmux.tabs.tab.", role: "AXRadioButton") }
    var dividers: Int { ax.identified("cmux.pane.divider.").count }

    func element(_ identifier: String) -> AXUIElement? {
        ax.elements().first { ax.string($0, kAXIdentifierAttribute) == identifier }
    }

    func pressMenu(_ action: String) -> String? {
        guard let item = ax.menuItem("cmux.action.\(action)") else { return "no menu item cmux.action.\(action)" }
        let error = ax.press(item)
        return error == .success ? nil : "AXPress cmux.action.\(action): \(error.rawValue)"
    }

    func pressID(_ identifier: String) -> String? {
        guard let target = element(identifier) else { return "no element \(identifier)" }
        let error = ax.press(target)
        return error == .success ? nil : "AXPress \(identifier): \(error.rawValue)"
    }

    func record(_ step: String, _ ok: Bool, _ detail: String) {
        let shots = options.out.appendingPathComponent("shots")
        let shot = shots.appendingPathComponent(String(format: "%02d-%@.png", results.count + 1, step))
        let problem = screenshot(pid: ax.pid, to: shot)
        results.append(StepResult(step: step, ok: ok, detail: problem.map { "\(detail); screenshot: \($0)" } ?? detail,
                                  screenshot: problem == nil ? shot.lastPathComponent : nil))
        print("\(ok ? "ok  " : "FAIL") \(step): \(detail)")
    }

    func run(_ step: String) {
        let settle = options.settle
        switch step {
        case "new-workspace":
            let before = workspaces
            if let problem = pressID("cmux.sidebar.newWorkspace") { return record(step, false, problem) }
            let ok = waitFor(settle) { workspaces.subtracting(before).count == 1 }
            record(step, ok, ok ? "new row \(workspaces.subtracting(before).first ?? "")" : "no new cmux.sidebar.workspace.* row")
        case "new-tab":
            let before = tabs
            if let problem = pressID("cmux.tabs.newTab") { return record(step, false, problem) }
            let ok = waitFor(settle) { tabs.subtracting(before).count == 1 }
            newTabID = tabs.subtracting(before).first
            record(step, ok, ok ? "new tab \(newTabID ?? "")" : "no new cmux.tabs.tab.* element")
        case "split-pane":
            let before = dividers
            if let problem = pressMenu("splitRight") { return record(step, false, problem) }
            let ok = waitFor(settle) { dividers == before + 1 }
            record(step, ok, "dividers \(before) -> \(dividers)")
        case "switch-tab":
            guard let target = ax.identified("cmux.tabs.tab.").first(where: {
                ax.string($0, kAXRoleAttribute) == "AXRadioButton" && ax.value($0) == 0
            }) else { return record(step, false, "no unselected tab") }
            let id = ax.string(target, kAXIdentifierAttribute)
            ax.press(target)
            let ok = waitFor(settle) { element(id).flatMap(ax.value) == 1 }
            record(step, ok, ok ? "selected \(id)" : "\(id) did not become selected")
        case "palette":
            if let problem = pressMenu("commandPalette") { return record(step, false, problem) }
            let shown = waitFor(settle) { element("cmux.commandPalette") != nil }
            record(step, shown, shown ? "cmux.commandPalette shows" : "cmux.commandPalette did not show")
            guard shown else { return }
            _ = pressMenu("commandPalette")
            if !waitFor(2, { element("cmux.commandPalette") == nil }), let palette = element("cmux.commandPalette") {
                AXUIElementPerformAction(palette, kAXCancelAction as CFString)
            }
            let closed = waitFor(settle) { element("cmux.commandPalette") == nil }
            record("palette-close", closed, closed ? "palette closed" : "palette still shows")
        case "settings":
            let before = ax.windows
            if let problem = pressMenu("openSettings") { return record(step, false, problem) }
            let opened = waitFor(settle) { ax.windows.count > before.count }
            let window = ax.windows.first { new in !before.contains { CFEqual($0, new) } }
            record(step, opened && window != nil, "windows \(before.count) -> \(ax.windows.count): \(window.map { ax.string($0, kAXTitleAttribute) } ?? "none")")
            guard let window, let close = ax.attr(window, kAXCloseButtonAttribute) else { return }
            // swiftlint:disable:next force_cast
            ax.press(close as! AXUIElement)
            let closed = waitFor(settle) { ax.windows.count == before.count }
            record("settings-close", closed, "windows -> \(ax.windows.count)")
        case "close-split":
            if let problem = pressMenu("closePane") { return record(step, false, problem) }
            let ok = waitFor(settle) { dividers == startDividers }
            record(step, ok, "dividers -> \(dividers) (start \(startDividers))")
        case "close-tab":
            guard let id = newTabID, let tab = element(id) else { return record(step, false, "the tour's tab is gone or was never made") }
            // Only a selected (or hovered) tab shows its x: select it, then press the x.
            ax.press(tab)
            guard waitFor(settle, { element("\(id).close") != nil }) else { return record(step, false, "\(id) shows no x") }
            if let problem = pressID("\(id).close") { return record(step, false, problem) }
            let ok = waitFor(settle) { !tabs.contains(id) }
            record(step, ok, ok ? "closed \(id)" : "\(id) still open")
        case "close-workspace":
            let created = workspaces.subtracting(startWorkspaces)
            guard created.count == 1, let id = created.first else { return record(step, false, "created workspaces: \(created.sorted())") }
            guard let row = element(id) else { return record(step, false, "no \(id)") }
            ax.press(row) // selects it, so Close Workspace acts on the tour's workspace
            if let problem = pressMenu("closeWorkspace") { return record(step, false, problem) }
            let ok = waitFor(settle) { !workspaces.contains(id) }
            record(step, ok, ok ? "closed \(id)" : "\(id) still open (a confirmation sheet?)")
        default:
            record(step, false, "unknown step")
        }
    }
}

// MARK: Main

let options = parse()
guard isTaggedDebugBundle(options.bundleID) else {
    fail("refusing --bundle-id '\(options.bundleID)': only a tagged debug build (com.cmuxterm.app.debug.<tag>) may be driven", code: 2)
}
guard AXIsProcessTrusted() else {
    fail("this process has no Accessibility grant; grant it to the terminal or host that runs the tour (never prompted here)", code: 2)
}
let running = NSRunningApplication.runningApplications(withBundleIdentifier: options.bundleID)
guard running.count == 1, let target = running.first, target.bundleIdentifier == options.bundleID else {
    fail("expected one running \(options.bundleID), found \(running.count); launch the tagged build first (reload.sh --tag)", code: 2)
}
let ax = AX(pid: target.processIdentifier)
if options.dump {
    for element in ax.elements() { print(ax.describe(element)) }
    exit(0)
}
try? FileManager.default.createDirectory(at: options.out.appendingPathComponent("shots"), withIntermediateDirectories: true)
let tour = Tour(ax: ax, options: options)
tour.startWorkspaces = tour.workspaces
tour.startTabs = tour.tabs
tour.startDividers = tour.dividers
let all = ["new-workspace", "new-tab", "split-pane", "switch-tab", "palette", "settings", "close-split", "close-tab", "close-workspace"]
for step in options.steps.isEmpty ? all : options.steps { tour.run(step) }
let manifest: [String: Any] = [
    "bundleID": options.bundleID,
    "result": tour.results.allSatisfy(\.ok) ? "pass" : "failed",
    "steps": tour.results.map { ["step": $0.step, "ok": $0.ok, "detail": $0.detail, "screenshot": ($0.screenshot as Any?) ?? NSNull()] as [String: Any] },
]
if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
    try? data.write(to: options.out.appendingPathComponent("manifest.json"))
}
print("manifest: \(options.out.appendingPathComponent("manifest.json").path)")
exit(tour.results.allSatisfy(\.ok) ? 0 : 1)
