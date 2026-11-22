import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.border))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A rounded panel that groups related content.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.border))
    }
}

/// A small pill that states one fact: "live", battery level, and so on.
struct Badge: View {
    let text: Text
    var systemImage: String?
    var tint = Theme.status

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            text
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.4)))
    }
}

/// A row of bars that fills with the sound level in the room.
struct SoundMeter: View {
    /// From 0 (silence) to 1 (full scale).
    let level: Double
    var barCount = 24

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(color(forBar: index))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.15), value: level)
        .accessibilityElement()
        .accessibilityLabel(Text("meter.accessibility"))
        .accessibilityValue(Text(level, format: .percent.precision(.fractionLength(0))))
    }

    private func color(forBar index: Int) -> Color {
        let position = Double(index) / Double(barCount)
        guard position < level else { return Theme.border }
        return position > 0.7 ? Theme.accent : Theme.status
    }
}

/// A square toggle with an icon and a label, such as "Night light".
struct ToggleTile: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isOn: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(isOn ? Theme.onAccent : Theme.text)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(isOn ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(isOn ? Theme.accent : Theme.border))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A label on the left, a value on the right.
struct InfoRow<Value: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 8)
            value
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
