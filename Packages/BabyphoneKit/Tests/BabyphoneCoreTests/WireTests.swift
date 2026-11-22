import Foundation
import Testing
@testable import BabyphoneCore

@Suite struct WireTests {
    @Test func decoderReassemblesFramesSplitAcrossChunks() throws {
        let first = Data("hello".utf8), second = Data(), third = Data(repeating: 9, count: 3000)
        var stream = Data()
        for payload in [first, second, third] {
            stream.append(try FrameCodec.encode(payload))
        }

        var decoder = FrameDecoder()
        var frames: [Data] = []
        var offset = 0
        for chunkSize in [1, 2, 3, 5, 700, 4000] {
            let chunk = stream.subdata(in: offset..<min(stream.count, offset + chunkSize))
            offset += chunk.count
            frames.append(contentsOf: try decoder.append(chunk))
        }
        #expect(frames == [first, second, third])
    }

    @Test func decoderRefusesOversizedFrames() {
        var decoder = FrameDecoder()
        #expect(throws: FrameChannelError.frameTooLarge) {
            try decoder.append(Data([0x7f, 0xff, 0xff, 0xff]))
        }
        #expect(throws: FrameChannelError.frameTooLarge) {
            try FrameCodec.encode(Data(count: FrameCodec.maxFrameSize + 1))
        }
    }

    @Test func messagesRoundTrip() throws {
        let event = JournalEvent(kind: .noise, origin: .baby, date: Date(timeIntervalSince1970: 1_800_000_000), duration: 12.5, revision: 4)
        let babyMessages: [BabyMessage] = [.status(MonitorStatus(soundLevel: 0.4, batteryLevel: 0.82, roomName: "Chambre")), .journal([event])]
        for message in babyMessages {
            #expect(try WireCoding.decode(BabyMessage.self, from: WireCoding.encode(message)) == message)
        }
        let parentMessages: [ParentMessage] = [.hello(lastJournalRevision: 12), .setNightLight(true), .setSensitivity(.high), .talking(false)]
        for message in parentMessages {
            #expect(try WireCoding.decode(ParentMessage.self, from: WireCoding.encode(message)) == message)
        }
    }

    @Test func receiveTimesOutByClosingTheChannel() async {
        let (channel, _) = MemoryChannel.pair()
        await #expect(throws: FrameChannelError.closed) {
            try await channel.receive(timeout: .milliseconds(30))
        }
    }
}
