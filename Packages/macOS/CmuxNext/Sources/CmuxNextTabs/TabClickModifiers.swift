/// Modifier keys that change what a tab click selects.
public struct TabClickModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// Cmd: toggle the tab in the selection.
    public static let toggle = TabClickModifiers(rawValue: 1 << 0)
    /// Shift: select the range from the anchor.
    public static let range = TabClickModifiers(rawValue: 1 << 1)
}
