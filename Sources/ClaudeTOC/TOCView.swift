import SwiftUI

struct TOCView: View {
    let headings: [TOCHeading]
    let totalLines: Int
    let onHeadingClick: (TOCHeading) -> Void
    let onDismiss: () -> Void

    @State private var hoveredIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack {
                Text("TOC")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()
                .padding(.horizontal, 8)

            // Headings list
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(headings.enumerated()), id: \.offset) { index, heading in
                        headingRow(heading, index: index)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: 260)
        .frame(maxHeight: 400)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 4)
    }

    @ViewBuilder
    private func headingRow(_ heading: TOCHeading, index: Int) -> some View {
        let indent: CGFloat = CGFloat((heading.level - 1) * 12)
        let isHovered = hoveredIndex == index

        Button(action: { onHeadingClick(heading) }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(colorForLevel(heading.level))
                    .frame(width: 4, height: 4)

                Text(heading.title)
                    .font(.system(size: fontSize(for: heading.level), weight: weight(for: heading.level)))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()
            }
            .padding(.leading, 12 + indent)
            .padding(.trailing, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                    .padding(.horizontal, 4)
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredIndex = inside ? index : nil
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private func colorForLevel(_ level: Int) -> Color {
        switch level {
        case 1: return .blue
        case 2: return .cyan
        default: return .gray
        }
    }

    private func fontSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return 13
        case 2: return 12
        default: return 11
        }
    }

    private func weight(for level: Int) -> Font.Weight {
        switch level {
        case 1: return .semibold
        case 2: return .medium
        default: return .regular
        }
    }
}
