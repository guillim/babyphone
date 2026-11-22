# Nid

An iPhone baby monitor made of two phones and nothing else. One iPhone stays in the baby's room, the other stays with the parent. Picture and sound go straight from one phone to the other. There is no server, no relay and no account.

"Nid" is a working name. It is set in one place, `Config/App.xcconfig`.

## Build it

You need Xcode 16 or later, two iPhones on iOS 16 or later, and a paid Apple Developer account (CloudKit requires one).

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and put your Team ID in it.
2. If `com.guillim.babyphone` is not the bundle identifier you want, change it in `Config/App.xcconfig`.
3. Open `Babyphone.xcodeproj`. Xcode fetches the two dependencies (WebRTC and GRDB) on first open.
4. Select the `Babyphone` scheme, choose an iPhone, and run. Do the same on the second iPhone.

Xcode creates the iCloud container `iCloud.<bundle identifier>` the first time it signs the app. The camera, the microphone and Bonjour do not work in the simulator, so the simulator only shows the screens.

## Use it

1. On each phone, pick a side: « Côté bébé » or « Côté parent ».
2. Pair them once, side by side: the parent phone scans the QR code shown on the baby phone, or you type its six digits.
3. On the baby phone, tap « Démarrer la surveillance ». The parent phone connects by itself.

At home the phones find each other over Wi-Fi with Bonjour. This needs neither internet nor iCloud. Away from home they find each other through iCloud, then connect directly over IPv6.

## How it is organised

| Path | Content |
| --- | --- |
| `Packages/BabyphoneKit`, `BabyphoneCore` | Every decision that needs no Apple framework: pairing, wire formats, connection logic, noise detection, database. Builds and tests on Linux and macOS. |
| `Packages/BabyphoneKit`, `BabyphoneTransport` | The real transports: the WebRTC peer connection, and the TCP and TLS channels on the local network. Its tests run the real stacks on a Mac. |
| `App/Services` | Thin adapters around the remaining Apple frameworks: camera, audio, CloudKit, notifications. |
| `App/Features` | One folder per screen, each with a SwiftUI view and its model. |
| `App/DesignSystem` | Colours, type and shared components. |
| `App/Resources` | Icon, colours, French and English strings. |
| `Config` | Bundle identifier, versions, Info.plist, entitlements. |

The connection logic lives in the core package behind three small protocols (`PeerSession`, `LocalSignalingListening` and `LocalSignalingConnecting`, `RendezvousProvider`). The tests run both phones' logic against each other over a simulated network.

`RendezvousProvider` is the single interface for finding the other phone remotely: publish my record, read the peer's. CloudKit implements it today. Another provider, such as a DHT, only has to implement the same two calls.

## How the phones connect

- **Pairing.** The two phones run a password-authenticated key exchange over the local link. The six-digit code or the QR token only proves that the phones are next to each other. The key they end up sharing has 256 bits, lives in the Keychain, and never travels.
- **Same network.** The baby phone advertises a Bonjour service. Signaling runs over TLS secured by the pairing key, so only the paired phone gets through.
- **Different networks.** The baby phone writes one small record to the CloudKit public database: its current addresses, encrypted with the pairing key, under an identifier derived from that key. The parent phone reads it and writes its own. Then both send to each other at the same time, which opens the firewalls on each side. Nothing else goes through CloudKit.
- **Media.** WebRTC with an empty ICE server list: host candidates only, so no STUN lookup and no TURN relay. Media is encrypted between the two phones.
- **No direct path.** There is no relay. The parent phone shows « Connexion directe impossible ».

## Choices made while building

These answer the open questions and proposals of the handoff brief. Each one is a single place to change.

| Topic | Choice | Where |
| --- | --- | --- |
| App name | "Nid", kept as a working name | `Config/App.xcconfig` |
| Bundle identifier | `com.guillim.babyphone` | `Config/App.xcconfig` |
| Minimum iOS | 16.0, so an iPhone 8 or later can serve as the baby phone | `Config/App.xcconfig` |
| Strong key under the 6-digit code (P1) | Yes. The parent still types six digits. | `Pairing/PasswordKeyExchange.swift` |
| Alerts (P2) | The live audio link is the main channel, with a local alarm when the link is lost. No CloudKit push. | `ParentMonitorModel.swift` |
| Network diagnostics screen (P3) | Yes: iCloud status, public IPv6, addresses in use, export of the night log | `DiagnosticsView.swift` |
| Wi-Fi first, remote later (P5) | Both are built. Wi-Fi works alone when iCloud is missing. | |
| Router port opening for IPv4 (P6) | Not built. Remote use needs IPv6 on both sides. | |
| Cry detection (P7) | Not built, as planned for V1 | |
| Audio clips in the journal | Not built. They were only in the mockups. | |
| Screen 6 copy | The promise that noise alerts keep arriving by notification is removed: without a link there is no reliable channel. | |
| Night light | Shines from the side of the camera in use: the torch with the rear camera, the screen with the front one | `BabyMonitorModel.swift` |
| Lullaby | Brahms' lullaby, synthesised by the app, so no audio file ships | `Audio/ToneSynthesizer.swift` |
| Peer-to-peer Wi-Fi | Used for pairing, so two phones can pair without a shared network. Not used for media: WebRTC does not send over it. | `LocalTransport.swift` |

## What is verified and what is not

Verified by automated tests:

- Pairing and its failure cases, the wire formats, noise detection, the journal and its sync, the encrypted rendezvous records.
- The connection logic of both phones against each other over a simulated network: local, remote, reconnection, every failure reason.
- The real WebRTC stack: two peer connections with an empty server list connect directly and exchange messages, including with an offer made long before its answer.
- The real secured channel: frames cross TLS keyed by the pairing key, and a phone with another key is refused.
- Both phones end to end over real TLS and real WebRTC, on the local path and through the rendezvous.

The whole app compiles in CI with the oldest and the newest supported Xcode.

Not verified, because it needs two real iPhones:

- Everything that touches hardware or an account: camera, microphone, speaker, torch, CloudKit.
- Bonjour discovery. Its tests exist and run on a Mac, but not in CI, where the local network is not available.
- The parent app staying alive in the background for a whole night, including after a phone call.
- The direct IPv6 connection through real home routers and mobile networks.
- Sound levels. The three noise thresholds in `Sensitivity.swift` are starting values to calibrate.
- The sound meter and the lullaby sharing the microphone and speaker with WebRTC.
- Sound on the parent phone. It listens with the playback audio category so that the microphone stays off outside talk-back. If the parent phone stays silent, this is the first place to look: `AudioSessionController.swift`.

## Before the first real night

1. **Overnight test.** Run both phones for eight hours. In the morning, open Réglages > Diagnostic réseau on each phone and export the night log. It holds one line a minute with battery, temperature and link state. A gap in the parent's lines means iOS suspended the app.
2. **IPv6 check.** The same screen says whether the phone has a public IPv6 address. Check it on your home Wi-Fi and on 4G or 5G. Remote use needs it on both sides.
3. **CloudKit schema.** The record type is created automatically in the Development environment on first use. Before TestFlight, deploy the schema to Production in the CloudKit Console.

## Tests

```sh
swift test --package-path Packages/BabyphoneKit   # core logic, WebRTC and network transports
python3 Scripts/localizations.py                  # every string exists in French and English
```

On Linux the first command runs the core tests only. In Xcode, ⌘U runs both test suites.
