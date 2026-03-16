import SwiftUI

struct TOCView: View {
    let headings: [TOCHeading]
    let totalLines: Int
    let onHeadingClick: (TOCHeading) -> Void
    let onDismiss: () -> Void

    @State private var hoveredIndex: Int? = nil
    @State private var dismissHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack {
                Image(systemName: "list.dash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(NoFeedbackButtonStyle())
                .onHover { inside in
                    dismissHovered = inside
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            

            // Headings list
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(headings.enumerated()), id: \.offset) { index, heading in
                        if index > 0 {
                            // Same group (child follows parent, or sibling at deeper level): tight spacing
                            // New group (same or shallower level as previous): wider spacing
                            let prevLevel = headings[index - 1].level
                            // Tight spacing within a group (child of parent, or siblings under same parent)
                            // Wide spacing when a new top-level section starts (level goes same or shallower)
                            let gap: CGFloat = heading.level > prevLevel || (heading.level == prevLevel && heading.level > minLevel) ? 0 : 8
                            Spacer().frame(height: gap)
                        }
                        headingRow(heading, index: index)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HorizontalBounceFixer())
            }
            .frame(maxWidth: .infinity)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        }
        .frame(width: 180)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: 300)
        .padding(.bottom, 6)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var minLevel: Int {
        headings.map(\.level).min() ?? 1
    }

    @ViewBuilder
    private func headingRow(_ heading: TOCHeading, index: Int) -> some View {
        let indent: CGFloat = CGFloat((heading.level - minLevel) * 6)
        let isHovered = hoveredIndex == index

        Button(action: { onHeadingClick(heading) }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.primary.opacity(isHovered ? 1.0 : 0.3))
                    .frame(width: 5, height: 5)

                Text(heading.title)
                    .font(.system(size: fontSize(for: heading.level), weight: weight(for: heading.level)))
                    .foregroundStyle(Color.primary.opacity(isHovered ? 1.0 : 0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()
            }
            .padding(.leading, 10 + indent)
            .padding(.trailing, 10)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(NoFeedbackButtonStyle())
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredIndex = inside ? index : nil
            }
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

private struct NoFeedbackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Finds the enclosing NSScrollView and disables horizontal elasticity.
/// Needed because SwiftUI provides no modifier for NSScrollView.horizontalScrollElasticity.
private struct HorizontalBounceFixer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let scrollView = view.enclosingScrollView {
                scrollView.horizontalScrollElasticity = .none
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
