# Home: no lag while a reply streams

Lawrence, 2026-10-20: "For the main iMessage home chat UI, when it is
streaming it is very laggy to do anything in general. Think from first
principles about how we can fix it so it is not laggy at all for streaming."

Scope: the cmux-next Mac Home transcript (`Packages/Shared/CmuxMessagesLab`,
MessagesLab appkit-native vendored plus the `Cmux/` glue) while a Chief reply
streams into it. Typing in the message box, scrolling, selecting, clicking and
switching tabs must feel the same as with no stream.

Owners of nearby work (read first, not duplicated here): a102 streaming
reply-split and clipped bubbles, a107 selection on layout shift, a175 scroll
snap-back, a150/a87 composer focus, a153 perf harness, a168 tab switch, the
drag-over fix 204546c37ef (`ProjectionCore.step` returns early on an unchanged
snapshot; `DragWhileStreamingTests`).

## First principles

1. **The main thread has one job per display frame: show the newest state
   within ~2 ms, then answer input.** At 60 Hz a frame is 16.7 ms, at 120 Hz
   8.3 ms. Input (a key, a scroll step, a click) is only as fast as the main
   thread is free. Anything the stream does on main is input latency.
2. **A token changes one thing: the tail of one bubble.** So the work per
   token must be O(size of the change), never O(reply length) and never
   O(transcript length). Settled messages and finished Markdown blocks are
   frozen: never mapped, parsed, measured, laid out or drawn again.
3. **The screen cannot show more than one state per frame.** Tokens arrive at
   50-200/s in bursts; the display shows 60-120 states/s. Every stream update
   past the first in a frame is wasted main-thread work. Coalesce to at most
   one stream update per display frame, latest text wins.
4. **Input goes first.** In a frame that has a keystroke (or scroll), the
   stream's update waits for the next frame; it is never in front of input.
   (MessagesLab already does this for statuses and typing: bd65bbf.)
5. **Expensive work happens off main, against an immutable snapshot, and
   main installs a finished result.** Parsing, Core Text measurement and
   rasterizing the bubble's bitmap are pure functions of (text, width,
   scale, palette). Main never waits for them; a newer token cancels or
   supersedes an older preparation.
6. **No layout pass for a frame that changes nothing on screen.** A token
   that only extends hidden text (the bubble is off screen because the person
   scrolled up) changes the document height and nothing else.
7. **Side effects are throttled and off main.** Persistence, sidebar rows,
   unread state, read cursors and the activity line do not run per token.

## Where the time goes today (per token)

From reading the code (numbers: "Measurements" below):

| step | where | cost shape |
| --- | --- | --- |
| store change -> `HomeProjection.refresh` | `HomeProjection+Observe` | once per store change (per token batch), not per frame |
| `items != shown`, summary compare | `HomeProjection.apply` | O(transcript) |
| map the stream bubble: `HomeMarkdown.render` + `TextParts.parts` of the whole text | `ProjectionCore.bubble` | O(reply) |
| `.streamSet` with the whole text: `StreamBubble` parts, `partVersion` hash | Engine | O(reply) |
| `deriveRows` from the newest message: `RowBuilder.rows` | WindowView.commit | O(reply) (measure) |
| `MeasureCache` miss every token: Markdown tail parse + `MDLines.split` of the whole text + stacking every block layout (block layouts cached) | Layout, MarkdownStore | O(reply) |
| model tail set, layout pass, springs (`animateRows`), `refreshVisibleCells` (every visible cell decorated) | WindowView.commit | O(visible rows) |
| the stream row's bitmap drawn **on main** (`RowCell.transitionDepth > 0` draws synchronously) | RowCell.configure | O(bubble area): the dominant cost for a tall bubble |

So the cost per token grows with the reply, and a long reply makes every
frame slower until input lags.

## Design

### 1. One stream update per display frame (glue)

`HomeProjection.observe` refreshes once per store change. A stream-only
change (the live run's text or `drafts`; transcript version, typing, rows and
confirmation unchanged) schedules one refresh on the next display frame
(`ChatController.nextFrame`), deduplicated: N tokens in one frame cost one
refresh. A transcript change refreshes now, as today, and carries the newest
stream text with it (the posted reply's hand-off stays in order).

In a keystroke frame (`controller.inKeystrokeFrame`) the stream update is
held to the next frame, like statuses and typing.

### 2. O(change) mapping and parsing (glue + vendored)

- The bubble mapping is incremental: the stream's text is a prefix-extension
  of the last one in the normal case; the rendered prefix up to the last
  completed top-level block (blank line outside a fence) is kept, and only the
  tail is rendered again. A text that is not an extension maps in full.
- `MarkdownStore` already parses only from the last top-level block; the
  remaining full-text passes (`MDLines.split` of the whole text, the 64-text
  prefix scan) are cut to the tail.

### 3. The stream row draws off main (vendored, patch)

The stream bubble's bitmap is rendered off main (`RowBitmaps.request`), and
the row's new geometry is shown together with its new bitmap in the frame the
bitmap lands (the old bitmap stays until then, never stretched, never empty).
Main never rasterizes the growing bubble. Long replies are tiled
(`TiledBubble`): only the end tiles change.

### 4. No commit work for nothing visible

A stream commit does not run springs for rows that do not move on screen,
decorates only the stream's cell and the rows below it (the status line),
and skips the layout pass when the bubble is off screen (only the document
height changes).

### 5. Side effects

Read cursor, older-page checks, attachment refresh and `onRowsChange` run
on transcript changes, not stream-only refreshes.

## Tests

`HomeStreamingPerfTests` (MessagesLabHomeTests, red first): the real
`MessagesLabHomeView` over a real `HomeStore` on the mock owner, a 5k-token
Markdown reply at two tokens per frame while typing, then while scrolling.
It asserts:

- per-frame main-thread streaming cost p95 < 4 ms, p99 < 8 ms, worst < 16 ms;
- the last 250 frames cost at most 2x the first 250 (+0.5 ms): cost follows
  the token, not the reply;
- a keystroke and a scroll step while streaming cost at most 1 ms more (p95)
  than with no stream.

Existing Home suites stay green (DragWhileStreaming, HomeSendOrder,
HomeSelectionStable, HomeScrollerDragTop, HomeResizeFollow, Golden).

## Measurements

(filled from the fleet runs: before and after)
