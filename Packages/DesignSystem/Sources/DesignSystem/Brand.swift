import SwiftUI

/// Brand tokens for chattr. This file is intentionally minimal for slice 1 —
/// the full Liquid Glass palette, typography, and material catalog lands in
/// a future slice once the chat path is working end-to-end.
public enum Brand {
    /// Accent color used for chattr's interactive elements.
    /// Picked to be distinguishable from Twitch's purple.
    public static let accent = Color(red: 0.20, green: 0.78, blue: 0.78)
}
