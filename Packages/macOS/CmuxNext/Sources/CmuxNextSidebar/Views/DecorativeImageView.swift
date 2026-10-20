import AppKit

/// An image that only decorates text beside it, so accessibility clients skip it: an unlabeled
/// `AXImage` is noise to VoiceOver and to computer-use agents that read the tree.
class DecorativeImageView: NSImageView {
    override func isAccessibilityElement() -> Bool { false }
}
