import AppKit
import CmuxNextDesign

extension TabCell {
    /// The fill of a tab selected with the shown tab: the selection fill at 60% of its alpha, so
    /// the shown tab still reads as the one in front (Chrome draws selected background tabs the
    /// same way). Theme-scoped: resolved inside `themeScope.perform`.
    static var multiSelectionFill: NSColor {
        let fill = Palette.selectionFill.usingColorSpace(.sRGB) ?? Palette.selectionFill
        return fill.withAlphaComponent(fill.alphaComponent * 0.6)
    }
}
