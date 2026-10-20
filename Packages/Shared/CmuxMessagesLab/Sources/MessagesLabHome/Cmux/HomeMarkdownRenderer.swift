/// `HomeMarkdown.render` for a text that grows at its end (an agent's streaming reply): the
/// same output, but a text that extends the last one resumes after the last line both share
/// (HomeMarkdown.Pass), and other lines come from a line cache. A token then renders its own
/// line, not the reply (plans/cmux-next/home-streaming-perf-DESIGN.md, 2).
///
/// Main thread only (the projection's).
final class HomeMarkdownRenderer {
    let lines: HomeMarkdownLineCache
    /// The source of the complete lines the kept pass rendered (through their last newline).
    private var kept = ""
    private var keptPass = HomeMarkdown.Pass()
    /// Renders that resumed after kept lines, for tests.
    private(set) var resumes = 0

    init(lines: HomeMarkdownLineCache = HomeMarkdownLineCache()) { self.lines = lines }

    func render(_ source: String) -> (text: String, runs: [TextRun]) {
        var pass: HomeMarkdown.Pass
        var rest: Substring
        let n = kept.utf8.count
        if n > 0, source.utf8.count >= n, source.utf8.starts(with: kept.utf8) {
            pass = keptPass
            rest = source[source.utf8.index(source.startIndex, offsetBy: n)...]
            resumes += 1
        } else {
            pass = HomeMarkdown.Pass()
            rest = source[...]
        }
        // Every line but the last ends at a newline: those are kept for the next text. A CR LF
        // pair is one Character and no line break to `split(separator: "\n")`: it stays in its line.
        var lineStart = rest.startIndex
        var sawNewline = false
        var i = rest.utf8.startIndex
        while let nl = rest.utf8[i...].firstIndex(of: 10) {
            i = rest.utf8.index(after: nl)
            if nl > rest.utf8.startIndex, rest.utf8[rest.utf8.index(before: nl)] == 13 { continue }
            pass.line(rest[lineStart..<nl], lines: lines)
            lineStart = i
            sawNewline = true
        }
        if sawNewline {
            kept = String(source[..<lineStart])
            keptPass = pass
        }
        pass.line(rest[lineStart...], lines: lines)
        return (pass.out.text, pass.out.runs)
    }
}
