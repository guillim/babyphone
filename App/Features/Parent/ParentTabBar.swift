import SwiftUI

/// The three screens of the parent unit.
enum ParentTab: Hashable {
    case live
    case journal
    case settings
}

/// The parent unit's navigation, floating at the bottom of every screen.
struct ParentTabBar: View {
    @Binding var selection: ParentTab
    /// An alert is waiting in the journal.
    let hasNews: Bool

    var body: some View {
        HStack(spacing: 0) {
            tab(.live, title: "parent.tab.live", systemImage: "video.fill")
                .accessibilityIdentifier("parent.tab.live")
            tab(.journal, title: "journal.title", systemImage: "list.bullet.rectangle")
                .overlay(alignment: .top) {
                    if hasNews {
                        Circle()
                            .fill(Theme.alert)
                            .frame(width: 9, height: 9)
                            .offset(x: 16, y: 7)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityIdentifier("parent.journal")
            tab(.settings, title: "settings.title", systemImage: "gearshape")
                .accessibilityIdentifier("parent.settings")
        }
        .padding(4)
        .glass(in: Capsule())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .readableWidth()
    }

    private func tab(_ tab: ParentTab, title: LocalizedStringKey, systemImage: String) -> some View {
        let isSelected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(isSelected ? .bold : .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Theme.accent : Theme.text)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(isSelected ? Color.white.opacity(0.14) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
