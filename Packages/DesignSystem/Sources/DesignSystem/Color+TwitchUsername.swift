import SwiftUI

/// Twitch-user color helpers.
///
/// Twitch lets each user pick a chat name color. Those colors are chosen for
/// readability on Twitch's dark UI — meaning many of them have very high
/// lightness (bright yellows, pale teals, light pinks) that look great on
/// dark grey but vanish against a white background.
///
/// `Color.twitchUsername(hex:scheme:)` clamps lightness in HSL so that:
///   - On light backgrounds, no username is brighter than ~45% lightness.
///   - On dark backgrounds, no username is darker than ~55% lightness.
///
/// Hue and saturation are preserved so each user's color identity stays
/// recognizable across appearance changes. This is the same approach used by
/// Twitch's own web client.
public extension Color {

    /// Parse a Twitch user color (e.g. `"#FFD700"`) and return a SwiftUI Color
    /// with lightness clamped for the given color scheme. Falls back to
    /// `.primary` when the hex string is empty or malformed.
    static func twitchUsername(hex: String, scheme: ColorScheme) -> Color {
        guard let rgb = RGB(hex: hex) else { return .primary }
        let hsl = rgb.toHSL()
        let clamped: HSL
        switch scheme {
        case .light:
            // Clamp lightness to ≤ 0.45 — keeps bright colors readable on white.
            clamped = HSL(h: hsl.h, s: hsl.s, l: min(hsl.l, 0.45))
        case .dark:
            // Clamp lightness to ≥ 0.55 — keeps dark colors readable on black/grey.
            clamped = HSL(h: hsl.h, s: hsl.s, l: max(hsl.l, 0.55))
        @unknown default:
            clamped = hsl
        }
        let out = clamped.toRGB()
        return Color(red: out.r, green: out.g, blue: out.b)
    }
}

// MARK: - Internal color model

/// Linear-RGB triple in 0...1 component range. Internal — exposed only as the
/// argument to the public `Color.twitchUsername(hex:scheme:)` entry point.
struct RGB {
    var r: Double
    var g: Double
    var b: Double

    /// Parse "#RRGGBB" or "RRGGBB". Returns nil for malformed input.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.r = Double((v >> 16) & 0xff) / 255
        self.g = Double((v >> 8) & 0xff) / 255
        self.b = Double(v & 0xff) / 255
    }

    init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    /// Standard HSL conversion. `l` is the midpoint of max+min channels — this
    /// is the same definition used by CSS `hsl()` and by Twitch's web client,
    /// not the HSV "value" used by UIColor.getHue.
    func toHSL() -> HSL {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let l = (maxC + minC) / 2

        guard maxC != minC else {
            // Achromatic — no hue / no saturation.
            return HSL(h: 0, s: 0, l: l)
        }

        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)

        let h: Double
        switch maxC {
        case r:
            h = (g - b) / d + (g < b ? 6 : 0)
        case g:
            h = (b - r) / d + 2
        default:
            h = (r - g) / d + 4
        }
        return HSL(h: h / 6, s: s, l: l)
    }
}

/// HSL triple. `h` and `s` and `l` are all in 0...1.
struct HSL {
    var h: Double
    var s: Double
    var l: Double

    /// Inverse of `RGB.toHSL()`. Standard CSS formula.
    func toRGB() -> RGB {
        guard s != 0 else {
            return RGB(r: l, g: l, b: l)
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return RGB(
            r: hueToChannel(p: p, q: q, t: h + 1.0 / 3.0),
            g: hueToChannel(p: p, q: q, t: h),
            b: hueToChannel(p: p, q: q, t: h - 1.0 / 3.0)
        )
    }

    private func hueToChannel(p: Double, q: Double, t: Double) -> Double {
        var t = t
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6.0 { return p + (q - p) * 6 * t }
        if t < 1.0 / 2.0 { return q }
        if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6 }
        return p
    }
}
