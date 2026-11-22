@preconcurrency import AVFoundation
import SwiftUI

/// A live camera view that reports the text of any QR code it sees.
struct QRScannerView: UIViewRepresentable {
    let onScan: @MainActor (String) -> Void

    func makeCoordinator() -> Scanner {
        Scanner(onScan: onScan)
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = context.coordinator.session
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Scanner) {
        coordinator.stop()
    }

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // Guaranteed by `layerClass`.
            layer as! AVCaptureVideoPreviewLayer
        }
    }

    final class Scanner: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        let session = AVCaptureSession()
        private let onScan: @MainActor (String) -> Void
        /// Starting and stopping a capture session blocks, so it stays off the main thread.
        private let queue = DispatchQueue(label: "nid.qr-scanner")

        init(onScan: @escaping @MainActor (String) -> Void) {
            self.onScan = onScan
        }

        func start() {
            Task {
                guard await AVCaptureDevice.requestAccess(for: .video) else { return }
                queue.async { [self] in
                    configure()
                    session.startRunning()
                }
            }
        }

        func stop() {
            queue.async { [session] in
                session.stopRunning()
            }
        }

        private func configure() {
            guard
                session.inputs.isEmpty,
                let camera = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: camera),
                session.canAddInput(input)
            else { return }
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.beginConfiguration()
            session.addInput(input)
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let text = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            Task { @MainActor [onScan] in
                onScan(text)
            }
        }
    }
}
