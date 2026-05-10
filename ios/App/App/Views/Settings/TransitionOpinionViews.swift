import SwiftUI
import UIKit

// MARK: - Star rating control (v12)

/// Rating control with five stars supporting half-star precision (0–10 in steps of 1).
/// Tap a star to set integer rating (each star = 2 points). Drag horizontally for
/// half-star precision. Active stars use a yellow→orange gradient for premium feel.
/// Animates with spring on change and emits selection haptic feedback.
struct StarRatingControl: View {
    @Binding var rating: Int   // 0...10. 0 means "not rated" UI-wise.
    var size: CGFloat = 36

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<5) { index in
                star(at: index)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    updateRating(for: value.location.x)
                }
        )
        .sensoryFeedback(.selection, trigger: rating)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(rating == 0 ? "Not rated" : "\(rating) out of 10")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if rating < 10 { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { rating += 1 } }
            case .decrement: if rating > 0  { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { rating -= 1 } }
            @unknown default: break
            }
        }
    }

    @ViewBuilder
    private func star(at index: Int) -> some View {
        let leftFilled  = rating >= (index * 2) + 1
        let rightFilled = rating >= (index * 2) + 2

        ZStack {
            // Background outline (always visible)
            Image(systemName: "star")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.tertiary)
                .frame(width: size, height: size)

            // Filled overlay with gradient — uses HStack of two halves to support half-stars
            HStack(spacing: 0) {
                halfStar(filled: leftFilled,  isLeft: true)
                halfStar(filled: rightFilled, isLeft: false)
            }
            .frame(width: size, height: size)
        }
        .scaleEffect(leftFilled || rightFilled ? 1.0 : 0.95)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: rating)
    }

    @ViewBuilder
    private func halfStar(filled: Bool, isLeft: Bool) -> some View {
        let starShape = Image(systemName: "star.fill")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(
                LinearGradient(
                    colors: [Color.yellow, Color.orange],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        starShape
            .frame(width: size / 2, height: size, alignment: isLeft ? .leading : .trailing)
            .clipped()
            .opacity(filled ? 1.0 : 0.0)
    }

    private func updateRating(for x: CGFloat) {
        // Total drag-area width ≈ size * 5 + spacing * 4. Map x → integer 0...10.
        let totalWidth = size * 5 + 6 * 4
        let normalized = max(0, min(1, x / totalWidth))
        let halfStarsTotal = 10
        let raw = normalized * CGFloat(halfStarsTotal)
        let snapped = Int(raw.rounded())
        let clamped = max(0, min(10, snapped))
        if rating != clamped {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                rating = clamped
            }
        }
    }
}

// MARK: - Rating badge (v12)

/// Compact pill shown in history list rows when a transition has been rated.
/// Yellow→orange gradient, monospaced digits, optional comment dot when there's
/// also a comment attached.
struct RatingBadge: View {
    let rating: Int
    let hasComment: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.caption2)
            Text("\(rating)")
                .font(.caption.monospacedDigit().weight(.bold))
            if hasComment {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(LinearGradient(
            colors: [.yellow, .orange],
            startPoint: .leading, endPoint: .trailing
        ))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.yellow.opacity(0.15), in: Capsule())
    }
}
