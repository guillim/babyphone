# NuzzleCam

A baby monitor made of the iPhones and iPads you already own, and nothing else. One device stays in the baby's room, and up to two others stay with the parents. Picture and sound go straight from one device to the other. There is no server, no relay and no account.

The name is set in one place, `Config/App.xcconfig`. The Bonjour services, the pairing link and the log subsystem carry it too, as `nuzzlecam`.

## Build it

You need Xcode 16 or later, two iPhones or iPads on iOS 16 or later, and a paid Apple Developer account (CloudKit requires one).

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and put your Team ID in it.
2. If `com.guillim.nuzzlecam` is not the bundle identifier you want, change it in `Config/App.xcconfig`.
3. Open `Babyphone.xcodeproj`. Xcode fetches the two dependencies (WebRTC and GRDB) on first open.
4. Select the `Babyphone` scheme, choose a device, and run. Do the same on the second device.

Xcode creates the iCloud container `iCloud.<bundle identifier>` the first time it signs the app. Simulators have no camera: two of them can pair and connect, with sound only and no picture.

## Use it

1. On each device, pick a side: « Côté bébé » or « Côté parent ».
2. Pair them once, side by side: the parent device scans the QR code shown on the baby device, or you type its six digits. Pairing starts on the sixth digit.
3. On the baby device, tap « Démarrer la surveillance ». The parent device connects by itself.

To add a second parent, open Réglages on the baby device while monitoring is stopped and choose « Ajouter un parent ». Each parent is paired separately and can be removed separately.

Leave the baby device plugged in and unlocked. Its screen dims by itself. If you lock it, iOS cuts the camera: the sound continues and the parent device shows that the picture is off.

At home the devices find each other over Wi-Fi with Bonjour. This needs neither internet nor iCloud. Away from home they find each other through iCloud, then connect directly over IPv6.

## How it is organised

| Path | Content |
| --- | --- |
| `Packages/BabyphoneKit`, `BabyphoneCore` | Every decision that needs no Apple framework: pairing, wire formats, connection logic, noise detection, database. Builds and tests on Linux and macOS. |
| `Packages/BabyphoneKit`, `BabyphoneTransport` | The real transports: the WebRTC peer connection, and the TCP and TLS channels on the local network. Its tests run the real stacks on a Mac. |
| `App/Services` | Thin adapters around the remaining Apple frameworks: camera, audio, CloudKit, notifications. |
| `App/Features` | One folder per screen, each with a SwiftUI view and its model. |
| `App/DesignSystem` | Colours, type and shared components. |
| `App/Resources` | Icon, colours, French and English strings. |
| `UITests` | Launches the app in a simulator, on the smallest supported iPhone and on an iPad, and walks every screen. Also drives a parent unit through a whole session with a baby unit running in a second simulator. |
| `Config` | Bundle identifier, versions, Info.plist, entitlements. |

The connection logic lives in the core package behind three small protocols (`PeerSession`, `LocalSignalingListening` and `LocalSignalingConnecting`, `RendezvousProvider`). The tests run both devices' logic against each other over a simulated network.

`RendezvousProvider` is the single interface for finding the other device remotely: publish my record, read the peer's. CloudKit implements it today. Another provider, such as a DHT, only has to implement the same two calls.

## How the devices connect

- **Pairing.** The two devices run a password-authenticated key exchange over the local link. The six-digit code or the QR token only proves that the devices are next to each other. The key they end up sharing has 256 bits, lives in the Keychain, and never travels.
- **Same network.** The baby device advertises a Bonjour service. Signaling runs over TLS secured by the pairing key, so only the paired device gets through.
- **Different networks.** The baby device writes one small record to the CloudKit public database: its current addresses, encrypted with the pairing key, under an identifier derived from that key. The parent device reads it and writes its own. Then both send to each other at the same time, which opens the firewalls on each side. Nothing else goes through CloudKit.
- **Media.** WebRTC with an empty ICE server list: host candidates only, so no STUN lookup and no TURN relay. Media is encrypted between the two devices.
- **IPv4 line at home.** The baby device asks the home router to forward one UDP port to it, with NAT-PMP or UPnP, and adds the router's public address to what it publishes. This happens on the local network only: the port stays open for an hour, is renewed while in use, and is given back when the connection ends.
- **No direct path.** There is no relay. The parent device shows « Connexion directe impossible ». While it has no direct link, it still reads the baby device's latest alerts in iCloud, once every 20 seconds: no picture, no sound, and no guarantee, which the screen says.

## Choices made while building

The decision numbers (D) and proposal numbers (P) are those of version 3 of the handoff brief. Each choice is a single place to change.

| Topic | Choice | Where |
| --- | --- | --- |
| App name | NuzzleCam | `Config/App.xcconfig` |
| Bundle identifier | `com.guillim.nuzzlecam` | `Config/App.xcconfig` |
| Devices (D13) | iPhone and iPad, iOS 16 or later, both roles. iPhone in portrait, iPad in any orientation. | `Config/App.xcconfig`, `Config/Info.plist` |
| Two parents (D11) | The baby unit keeps one key, one Bonjour service, one rendezvous record and one connection per parent. Audio-only is each parent's own choice. Night light, lullaby, white noise and sensitivity are shared. | `BabyMonitorModel.swift` |
| Strong key under the code (D21) | A password-authenticated key exchange. The parent still types six digits. | `Pairing/PasswordKeyExchange.swift` |
| Reconnection (D14) | Each side signals every 2 s. After 10 s of silence the link is dropped and rebuilt. A picture that stops arriving for 15 s while the link answers also triggers a reconnection. | `Link/PeerLink.swift`, `ParentMonitorModel.swift` |
| Alerts (D18) | A chime for noise and power alerts, and a looping alarm 10 s after an unrecovered link loss. Both play through the app's own audio, so they are heard on silent and in a Focus mode. Notifications only add to this when the app is in the background. | `Audio/ParentAudio.swift` |
| Noise calibration (D20) | The detector follows the room's steady background level. The presets set how far above it a sound must rise: 8, 15 or 24 dB. | `Monitoring/NoiseDetector.swift` |
| Power alert (D15) | When the charger is removed, and when the battery falls under 20 % unplugged | `Monitoring/PowerWatch.swift` |
| Zoom (D16) | Zoom is done on the parent's screen, up to 4 times, so each parent zooms independently. | `MediaEngine.swift`, `ParentLiveView.swift` |
| White noise (D17) | Synthesised by the app, for 15, 30 or 60 minutes | `Audio/ToneSynthesizer.swift` |
| Failure screen (D19) | Guided fixes: personal hotspot, or mobile data on both sides | `ConnectionFailedView.swift` |
| Diagnostic view (P1) | Built: iCloud status, public IPv6, addresses, last signal, path in use, manual reconnection, export of the night log | `DiagnosticsView.swift` |
| Wi-Fi first, remote later (P3) | Both are built. Wi-Fi works alone when iCloud is missing. | |
| Router port opening for IPv4 (P4) | Built, for the baby side: NAT-PMP first, then UPnP. The router is addressed directly, so the app needs no multicast permission from Apple. A router that shares its address with other customers is detected and left alone. PCP is not spoken. | `Network/PortMapping`, `RouterPortMapper.swift` |
| Cry detection (P5) | Built on the sound classifier that ships in iOS, on the baby device. A cry starts after one second of confidence and ends after eight seconds of quiet. Each parent can choose to be alerted about crying only. That choice falls back to any noise when the baby device cannot recognise crying. | `Monitoring/CryDetector.swift`, `CryClassifier.swift` |
| Alarm volume, mute and snooze (P6) | Three volumes, on top of the device's own. The alarm can be silenced. Noise and cry alerts can be paused for 10, 30 or 60 minutes. A lost link and a power problem always ring. | `Monitoring/AlertPolicy.swift` |
| Alerts-only mode through iCloud (P7) | Built. The baby device writes its state and last events once a minute and at each alert, for each parent that has no direct link. The record is encrypted like the addresses. | `Alerts/` |
| Audio clips in the journal | Not built. They were only in the mockups. | |
| Night light | Shines from the side of the camera in use: the torch with the rear camera, the screen with the front one or on a device without a torch | `BabyMonitorModel.swift` |
| Lullaby | Brahms' lullaby, synthesised by the app, so no audio file ships | `Audio/ToneSynthesizer.swift` |
| Peer-to-peer Wi-Fi | Used for pairing, so two devices can pair without a shared network. Not used for media: WebRTC does not send over it. | `LocalTransport.swift` |

## What is verified and what is not

Verified by automated tests:

- Pairing and its failure cases, the wire formats, noise detection, the journal and its sync, the encrypted rendezvous records.
- When a cry starts and ends, what a pause quietens and what it never does, and the alerts left in the rendezvous provider and read back.
- The router protocols: the exact NAT-PMP bytes, the UPnP search, description and commands, and both against a router simulated on the Mac, including a port already taken and a shared address.
- The connection logic of both devices against each other over a simulated network: local, remote, reconnection, every failure reason.
- The real WebRTC stack: two peer connections with an empty server list connect directly and exchange messages, including with an offer made long before its answer.
- The real secured channel: frames cross TLS keyed by the pairing key, and a device with another key is refused.
- Both devices end to end over real TLS and real WebRTC, on the local path and through the rendezvous, and two parents connected to the same baby unit at once.
- The app itself in a simulator, on an iPhone SE, an iPhone 17 and an iPad: it starts, every screen appears, and the parent's controls fit an iPhone SE without scrolling.
- The two apps together, in two simulators: pairing with the six-digit code, Bonjour discovery and connection over the local network, night light, lullaby and white noise commands over the live link, the journal sync, and a deliberate stop.

The whole app compiles in CI with the oldest and the newest supported Xcode.

Not verified, because it needs two real iPhones:

- Everything that touches hardware or an account: camera, microphone, speaker, torch, CloudKit.
- Two parents on real devices. The connections are tested, the two encodes on an old device are not.
- Peer-to-peer Wi-Fi during pairing, which simulators do not have.
- The parent app staying alive in the background for a whole night, including after a phone call.
- The router port on a real router. The protocols are tested against a simulated one. Real routers differ, some answer only a search sent to the whole network, which iOS allows only with a permission from Apple, and a parent on an IPv6-only mobile network cannot use an IPv4 port.
- Cry detection on a real baby. The classifier is Apple's, and how often it is right in a real room is unknown. The thresholds in `CryDetector.swift` are starting values.
- Alerts through iCloud on real accounts: how late they arrive, and how long iOS lets the parent app poll in the background.
- The direct IPv6 connection through real home routers and mobile networks.
- Sound levels. The three noise thresholds in `Sensitivity.swift` are starting values to calibrate.
- The sound meter and the lullaby sharing the microphone and speaker with WebRTC.
- Audio routing on real devices. The baby device uses the audio configuration WebRTC is built for (play and record, voice processing, loudspeaker). The parent device gives WebRTC its own audio device (`ParentAudio.swift`): the baby's sound plays as plain playback, at the phone's media volume, and the microphone opens only while the talk button is held, with the baby's sound muted for that moment so it is not sent back.

## Before the first real night

1. **Overnight test.** Run both devices for eight hours, then once more with two parents connected. In the morning, open Réglages > Diagnostic réseau on each device and export the night log. It holds one line a minute with battery, temperature and link state. A gap in the parent's lines means iOS suspended the app. For a connection that dropped, plug the device into a Mac, open Console and filter on the subsystem `nuzzlecam`: every decision about the link is traced there.
2. **IPv6 check.** The same screen says whether the device has a public IPv6 address. Check it on your home Wi-Fi and on 4G or 5G. Without it at home, run « Tester l'ouverture d'un port » on the baby device: it says whether your router can open the IPv4 path instead.
3. **CloudKit schema.** The record type is created automatically in the Development environment on first use. Before TestFlight, deploy the schema to Production in the CloudKit Console.

## Send it to TestFlight

The TestFlight workflow archives the app and uploads it: Actions tab > TestFlight > Run workflow. It needs four repository secrets, listed at the top of `.github/workflows/testflight.yml`, and the app must already exist in App Store Connect under the bundle identifier. The build number is the run number. It has not run yet: no secret was available when it was written.

## Tests

```sh
swift test --package-path Packages/BabyphoneKit   # core logic, WebRTC and network transports
python3 Scripts/localizations.py                  # every string exists in French and English
```

On Linux the first command runs the core tests only. In Xcode, ⌘U runs everything, including the walk through the screens in the selected simulator.

No test waits without a limit. Every wait in the test helpers has a deadline, and `Scripts/test-with-watchdog.sh` stops a run that goes silent and prints where each thread is stuck.

Two workflows run on GitHub:

| Workflow | When | Checks | Duration |
| --- | --- | --- | --- |
| `CI` | Every push | Core tests on Linux, strings, then on the oldest and newest Xcode: all package tests, the transport tests five more times, and the app build | About 5 minutes |
| `Simulators` | Every night, on demand, and when the UI tests change | The walk through the screens on an iPhone SE, an iPhone 17 and an iPad, and the two-device session | 8 to 15 minutes for the screens, 15 to 30 for the two-device session. Nearly all of it is spent starting simulators, and build machines vary a lot. |

`CI` is the gate. To run `Simulators` on a commit, open the Actions tab, choose the workflow and press « Run workflow ».

## License

[MIT](LICENSE)
