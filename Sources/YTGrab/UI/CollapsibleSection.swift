import SwiftUI

/// Full-width disclosure row: the entire header is the hit target (unlike
/// DisclosureGroup on macOS where only the chevron toggles). Content
/// fades in/out below with an opacity transition.
struct CollapsibleSection<Content: View>: View {
    let title: String
    let isExpanded: Binding<Bool>
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    init(
        _ title: String, isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    Text(title)
                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(
                    maxWidth: .infinity, minHeight: 28,
                    alignment: .leading
                )
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            hovering
                                ? Color.primary.opacity(0.08)
                                : Color.clear))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded.wrappedValue ? "expanded" : "collapsed")
            .accessibilityAddTraits(.isButton)
            .help("Show or hide settings")

            if isExpanded.wrappedValue {
                content()
                    .transition(.opacity)
            }
        }
    }
}
