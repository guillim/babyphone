import BabyphoneCore
import SwiftUI

/// Parent side of pairing: scan the QR code shown on the baby unit, or type its six digits.
struct ParentPairingView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model = ParentPairingModel()
    @FocusState private var isCodeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("pairing.title")
                    .font(Theme.heading(.title2))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)

                QRScannerView { payload in
                    model.handleScan(payload, onPaired: finish)
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.border))
                .overlay {
                    if model.isPairing {
                        ZStack {
                            Color.black.opacity(0.6)
                            ProgressView()
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    }
                }

                Text("pairing.parent.instructions")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)

                TextField("pairing.code.placeholder", text: $model.code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(.title2, design: .monospaced).weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.text)
                    .frame(minHeight: 52)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.border))
                    .focused($isCodeFocused)
                    .accessibilityIdentifier("pairing.codeField")
                    .onChange(of: model.code) { newValue in
                        let digits = String(newValue.filter(\.isNumber).prefix(6))
                        if digits != newValue { model.code = digits }
                    }

                Button("pairing.submit") {
                    isCodeFocused = false
                    model.submitCode(onPaired: finish)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canSubmitCode)
                .accessibilityIdentifier("pairing.submit")

                if let failure = model.failure {
                    Text(message(for: failure))
                        .font(.footnote)
                        .foregroundStyle(Theme.alert)
                        .multilineTextAlignment(.center)
                }
                Text("pairing.note")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)

                Button("pairing.changeRole") {
                    Task { await app.resetRole() }
                }
                .font(.footnote.weight(.semibold))
                .frame(minHeight: Theme.minimumTouchTarget)
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var finish: @MainActor (PairingKey) -> Void {
        { key in Task { await app.completePairing(as: .parent, with: key) } }
    }

    private func message(for failure: ParentPairingModel.Failure) -> LocalizedStringKey {
        switch failure {
        case .wrongCode: "pairing.error.wrongCode"
        case .babyNotFound: "pairing.error.notFound"
        case .localNetworkDenied: "pairing.localNetworkDenied"
        case .incompatibleVersion: "pairing.error.incompatible"
        }
    }
}
