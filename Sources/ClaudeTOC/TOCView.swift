import SwiftUI

struct TOCView: View {
    let headings: [TOCHeading]
    let totalLines: Int
    let onHeadingClick: (TOCHeading) -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredIndex: Int? = nil
    @State private var dismissHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack {
                Image(systemName: "list.dash")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(Color.primary.opacity(0.8))
                    
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                        .adaptiveGlass(.regular, shape: .circle)
                }
                .buttonStyle(NoFeedbackButtonStyle())
                .onHover { inside in
                    dismissHovered = inside
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.top, 12)
            

            // Headings list
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(headings.enumerated()), id: \.offset) { index, heading in
                        if index > 0 {
                            Spacer().frame(height: gap(before: index))
                        }
                        headingRow(heading, index: index)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HorizontalBounceFixer())
            }
            .frame(maxWidth: .infinity)
            .frame(height: min(contentNaturalHeight, Self.maxScrollHeight), alignment: .top)
            .compatScrollBounce()
        }
        .frame(width: 180)
        .padding(.bottom, 12)
        .adaptiveGlass(.panel, colorScheme: colorScheme)
    }

    private static let maxScrollHeight: CGFloat = 300
    private static let rowHeight: CGFloat = 20
    private static let verticalPadding: CGFloat = 16

    private var minLevel: Int {
        headings.map(\.level).min() ?? 1
    }

    private func gap(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let current = headings[index]
        let prev = headings[index - 1]
        return current.level > prev.level || (current.level == prev.level && current.level > minLevel) ? 0 : 8
    }

    /// Computed synchronously because NSHostingView.fittingSize reads size before
    /// any PreferenceKey/GeometryReader callback would have fired.
    private var contentNaturalHeight: CGFloat {
        var h: CGFloat = Self.verticalPadding
        for i in 0..<headings.count {
            h += gap(before: i) + Self.rowHeight
        }
        return h
    }

    @ViewBuilder
    private func headingRow(_ heading: TOCHeading, index: Int) -> some View {
        let indent: CGFloat = CGFloat((heading.level - minLevel) * 8)
        let isHovered = hoveredIndex == index

        Button(action: { onHeadingClick(heading) }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.primary.opacity(isHovered ? 1.0 : 0.3))
                    .frame(width: 4, height: 4)

                Text(heading.title)
                    .font(.system(size: fontSize(for: heading.level), weight: weight(for: heading.level)))
                    .foregroundStyle(Color.primary.opacity(isHovered ? 1.0 : 0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()
            }
            .padding(.leading,2 + indent)
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
        case 2: return 13
        default: return 13
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

// MARK: - Glass Effect Compatibility

enum AdaptiveGlassStyle {
    case regular  // close button
    case panel    // full panel background
}

extension View {
    @ViewBuilder
    func adaptiveGlass(_ style: AdaptiveGlassStyle, shape: some InsettableShape = RoundedRectangle(cornerRadius: 24), colorScheme: ColorScheme = .dark) -> some View {
        if #available(macOS 26, *) {
            switch style {
            case .regular:
                self.glassEffect(.regular.interactive(), in: .circle)
            case .panel:
                self.background(colorScheme == .light ? Color.white.opacity(0.25) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .glassEffect(.clear, in: .rect(cornerRadius: 24))
            }
        } else {
            switch style {
            case .regular:
                self.background(.ultraThinMaterial, in: Circle())
            case .panel:
                self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
        }
    }
}

extension View {
    @ViewBuilder
    func compatScrollBounce() -> some View {
        if #available(macOS 13.3, *) {
            self.scrollBounceBehavior(.basedOnSize, axes: .vertical)
        } else {
            self
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
