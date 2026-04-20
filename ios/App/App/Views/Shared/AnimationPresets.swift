import SwiftUI

// MARK: - Centralized animation presets (Apple Music-style consistency)

/// Standard animation presets for the entire app.
/// Use these instead of inline spring/easing values to maintain visual consistency.
enum Anim {
    // MARK: Springs

    /// Fast dismissals, button state changes, small UI reactions (0.35s)
    static let quick = Animation.spring(response: 0.35, dampingFraction: 0.88)

    /// Entrance animations, moderate transitions (0.45s)
    static let moderate = Animation.spring(response: 0.45, dampingFraction: 0.88)

    /// Large-scale transitions like viewer open/close (0.5s)
    static let expand = Animation.spring(response: 0.5, dampingFraction: 0.92)

    /// Interactive drag feedback (0.35s, slightly less damped for responsiveness)
    static let interactive = Animation.interactiveSpring(response: 0.35, dampingFraction: 0.86)

    /// Playback state (play/pause artwork scale) — bouncy, expressive (0.55s)
    static let playback = Animation.spring(response: 0.55, dampingFraction: 0.72)

    // MARK: Easing

    /// Micro-interactions: icon toggles, label reveals (0.15s)
    static let micro = Animation.easeInOut(duration: 0.15)

    /// Small state changes: button feedback, visibility toggles (0.2s)
    static let small = Animation.easeInOut(duration: 0.2)

    /// Content state changes: section toggles, lyrics scroll (0.3s)
    static let content = Animation.easeInOut(duration: 0.3)

    /// Accent/color transitions: background fades, palette shifts (0.4s)
    static let color = Animation.easeInOut(duration: 0.4)
}
