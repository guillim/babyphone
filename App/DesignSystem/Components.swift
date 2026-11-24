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
        .accessibilityElement(children: .combine)
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

extension View {
    /// The surface of a control that floats over the picture: Liquid Glass where
    /// the system has it, a blurred material with a hairline before that.
    /// `outline` draws a coloured rim, for a control that must stand out.
    @ViewBuilder
    func glass(in shape: some InsettableShape, outline: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
                .overlay(shape.strokeBorder(outline ?? .clear, lineWidth: 1))
        } else {
            materialGlass(in: shape, outline: outline)
        }
        #else
        materialGlass(in: shape, outline: outline)
        #endif
    }

    private func materialGlass(in shape: some InsettableShape, outline: Color?) -> some View {
        background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(outline ?? Color.white.opacity(0.16), lineWidth: 1))
    }
}

extension View {
    /// Keeps content at a comfortable width and centres it, so a screen built for
    /// an iPhone does not stretch across an iPad.
    func readableWidth(_ maxWidth: CGFloat = 560) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
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
