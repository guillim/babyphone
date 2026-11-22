import BabyphoneCore
import SwiftUI

/// First launch: each phone picks its side. No sign-up, no account.
struct RoleSelectionView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text(verbatim: AppInfo.name)
                        .font(Theme.heading(.largeTitle))
                        .foregroundStyle(Theme.accent)
                    Text("role.title")
                        .font(Theme.heading(.title2))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 32)

                roleButton(.baby, title: "role.baby.title", detail: "role.baby.detail", systemImage: "moon.stars.fill")
                    .accessibilityIdentifier("role.baby")
                roleButton(.parent, title: "role.parent.title", detail: "role.parent.detail", systemImage: "figure.and.child.holdinghands")
                    .accessibilityIdentifier("role.parent")

                Text("role.footer")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
            .padding(20)
        }
    }

    private func roleButton(_ role: DeviceRole, title: LocalizedStringKey, detail: LocalizedStringKey, systemImage: String) -> some View {
        Button {
            Task { await app.choose(role) }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.title)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Theme.heading(.title3))
                        .foregroundStyle(Theme.text)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.border))
        }
        .buttonStyle(.plain)
    }
}
