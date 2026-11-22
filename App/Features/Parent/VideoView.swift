import SwiftUI
@preconcurrency import WebRTC

/// Renders the picture received from the baby unit.
struct VideoView: UIViewRepresentable {
    let track: RTCVideoTrack?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        guard context.coordinator.track !== track else { return }
        context.coordinator.track?.remove(view)
        context.coordinator.track = track
        track?.add(view)
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view)
        coordinator.track = nil
    }

    final class Coordinator {
        var track: RTCVideoTrack?
    }
}
