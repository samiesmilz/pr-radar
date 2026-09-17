import Foundation

/// Which colour scheme the app draws in.
///
/// The app has always followed the system, and `.system` keeps that — this adds
/// the ability to pin one, which is the part that was missing. Worth having
/// because the badge floats over whatever is behind it: someone who works in a
/// light editor on a dark desktop has a correct system answer that is still the
/// wrong answer for this one window.
///
/// Kept free of AppKit so the icon generator, which has no window server, can
/// read the same choice — the same split `Health` already uses, with the colour
/// values in this module and the `Color` in the app.
public enum Appearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    public var title: String {
        switch self {
        case .system: return "Match system"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}
