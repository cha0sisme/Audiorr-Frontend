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

// MARK: - Opinion section card (v12)

/// "My Opinion" card shown at the top of TransitionDetailView. Displays current
/// rating + comment, lets the user tap stars to adjust rating, and tap the comment
/// row to open a full-screen sheet for editing. Auto-saves to JSON via
/// TransitionDiagnostics.updateOpinion. Visual style: regularMaterial card with
/// subtle shadow, rounded 20pt corners — Apple HIG iOS 26.
struct OpinionCard: View {
    let recordId: UUID
    @Binding var rating: Int
    @Binding var comment: String
    let onCommit: (Int, String) -> Void

    @State private var showCommentSheet = false
    @State private var lastSavedRating: Int
    @State private var lastSavedComment: String

    init(recordId: UUID, rating: Binding<Int>, comment: Binding<String>, onCommit: @escaping (Int, String) -> Void) {
        self.recordId = recordId
        self._rating = rating
        self._comment = comment
        self.onCommit = onCommit
        self._lastSavedRating = State(initialValue: rating.wrappedValue)
        self._lastSavedComment = State(initialValue: comment.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Label("My Opinion", systemImage: "star.bubble.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if rating > 0 {
                    Text("\(rating)/10")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(LinearGradient(
                            colors: [.yellow, .orange],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.yellow.opacity(0.15), in: Capsule())
                } else {
                    Text("Not rated")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            // Stars
            HStack {
                Spacer()
                StarRatingControl(rating: $rating, size: 38)
                Spacer()
            }
            .padding(.vertical, 4)

            Divider()

            // Comment row — tappable, opens sheet
            Button {
                showCommentSheet = true
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: comment.isEmpty ? "text.bubble" : "text.bubble.fill")
                        .font(.body)
                        .foregroundStyle(comment.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(comment.isEmpty ? "Add a comment" : "Comment")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        if !comment.isEmpty {
                            Text(comment)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        } else {
                            Text("Notes about this transition…")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
        .onChange(of: rating) { _, newValue in
            // Auto-save on every star change (debounced via state comparison).
            if newValue != lastSavedRating {
                lastSavedRating = newValue
                onCommit(newValue, comment)
            }
        }
        .sheet(isPresented: $showCommentSheet) {
            CommentEditorSheet(
                comment: $comment,
                onSave: {
                    if comment != lastSavedComment {
                        lastSavedComment = comment
                        onCommit(rating, comment)
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Comment editor sheet (v12)

/// Modal sheet for editing a transition comment. Uses TextEditor with axis-resizing
/// and a focused state to keep the keyboard up. Save button on top-trailing,
/// Cancel discards changes via @Binding sync model (caller passes onSave).
private struct CommentEditorSheet: View {
    @Binding var comment: String
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var draft: String

    init(comment: Binding<String>, onSave: @escaping () -> Void) {
        self._comment = comment
        self.onSave = onSave
        self._draft = State(initialValue: comment.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("Notes about this transition. They’ll be exported with the diagnostic data when you share the session file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)

                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxHeight: .infinity)
                    .focused($isFocused)
                    .onAppear { isFocused = true }
            }
            .padding(16)
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        comment = draft
                        onSave()
                        dismiss()
                    } label: {
                        Text("Save").bold()
                    }
                }
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
