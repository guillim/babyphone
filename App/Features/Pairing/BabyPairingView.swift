import BabyphoneCore
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Baby side of pairing: a QR code to scan, and six digits for those who prefer typing.
struct BabyPairingView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model = BabyPairingModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("pairing.title")
                    .font(Theme.heading(.title2))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                Text("pairing.baby.instructions")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)

                if let invitation = model.invitation {
                    if let code = QRCode.image(for: invitation.qrPayload) {
                        Image(uiImage: code)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220)
                            .padding(12)
                            .background(.white, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                            .accessibilityLabel(Text("pairing.qr.accessibility"))
                    }
                    Card {
                        VStack(spacing: 6) {
                            Text("pairing.code.label")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryText)
                            Text(invitation.code)
                                .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                                .kerning(6)
                                .foregroundStyle(Theme.accent)
                                .accessibilityLabel(Text(invitation.code.map(String.init).joined(separator: " ")))
                                .accessibilityIdentifier("pairing.code")
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    ProgressView()
                        .padding(40)
                }

                if model.isUnreachable {
                    Text("pairing.localNetworkDenied")
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
                .accessibilityIdentifier("pairing.changeRole")
            }
            .padding(20)
        }
        .onAppear {
            model.start { key in
                Task { await app.completePairing(as: .baby, with: key) }
            }
        }
        .onDisappear { model.stop() }
    }
}

enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard
            let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
            let rendered = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: rendered)
    }
}
