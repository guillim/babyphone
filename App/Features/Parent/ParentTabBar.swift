import SwiftUI

/// The three screens of the parent unit.
enum ParentTab: Hashable {
    case live
    case journal
    case settings
}

/// The parent unit's navigation, floating at the bottom of every screen, with
/// the talk button beside it so that it is always one press away.
struct ParentTabBar: View {
    @Binding var selection: ParentTab
    /// An alert is waiting in the journal.
    let hasNews: Bool
    let isTalking: Bool
    let canTalk: Bool
    let onTalk: @MainActor (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
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
            TalkButton(isTalking: isTalking, isEnabled: canTalk, onChange: onTalk)
        }
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

/// The main button of the parent unit: hold it to talk to the baby.
private struct TalkButton: View {
    let isTalking: Bool
    let isEnabled: Bool
    let onChange: @MainActor (Bool) -> Void
    /// Resets by itself when the system cancels the touch, which `onEnded` never reports.
    @GestureState private var isPressed = false
    @State private var pressStart = Date.distantPast
    /// A round button cannot say that it must be held. A short tap makes it say so.
    @State private var isShowingHint = false

    /// A press shorter than this is a tap, which sends nothing worth hearing.
    private static let shortestHold: TimeInterval = 0.4

    var body: some View {
        Image(systemName: isTalking ? "mic.fill" : "mic")
            .font(.title2.weight(.semibold))
            .foregroundStyle(isTalking ? Theme.onAccent : Theme.accent)
            .frame(width: 60, height: 60)
            .background(isTalking ? Theme.status : Theme.accent.opacity(0.14), in: Circle())
            .glass(in: Circle(), outline: Theme.accent.opacity(0.5))
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(isTalking ? 1.08 : 1)
            .animation(.easeOut(duration: 0.12), value: isTalking)
            // A zero-distance drag reports both the press and the release, which a tap cannot.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, isPressed, _ in isPressed = true }
            )
            .onChange(of: isPressed) { isPressed in
                onChange(isPressed && isEnabled)
                if isPressed {
                    pressStart = Date()
                    isShowingHint = false
                } else if isEnabled, Date().timeIntervalSince(pressStart) < Self.shortestHold {
                    isShowingHint = true
                }
            }
            // A press held while the link comes up starts talking then.
            .onChange(of: isEnabled) { isEnabled in
                if isPressed { onChange(isEnabled) }
            }
            .task(id: isShowingHint) {
                guard isShowingHint, (try? await Task.sleep(for: .seconds(2))) != nil else { return }
                isShowingHint = false
            }
            .accessibilityElement()
            .accessibilityLabel(Text("parent.talk"))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("parent.talk")
            .overlay(alignment: .topTrailing) {
                if let caption {
                    Text(caption)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .glass(in: Capsule())
                        .fixedSize()
                        // Sits just above the button, its right edge on the button's.
                        .alignmentGuide(.top) { $0[.bottom] + 8 }
                        .accessibilityHidden(true)
                }
            }
    }

    /// What the button says above itself: that the parent is heard, or how to be.
    private var caption: LocalizedStringKey? {
        if isTalking { return "parent.talk.active" }
        return isShowingHint ? "parent.talk" : nil
    }
}
