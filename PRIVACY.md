# NuzzleCam privacy policy

Last updated: 26 November 2026

NuzzleCam is a baby monitor made of two or three of your own iPhones or iPads. This page says what happens to your data when you use it. A French version follows the English one.

## In short

- We run no server. We receive no picture, no sound and no information about you.
- There is no account, no advertising, no analytics and no tracking.
- Picture and sound go straight from the device in the baby's room to the parent's device, encrypted between the two.

## What the app uses on your devices

- **Camera and microphone.** The device in the baby's room films and listens to the room, and sends this live to the parent devices you paired with it. The parent device uses its camera only to scan the pairing code, and its microphone only while you hold the talk button. The app records neither picture nor sound.
- **Local network.** At home, the devices find each other over your Wi-Fi and connect directly. The device in the baby's room may ask your router to open one port, so that it can be reached from outside. The port is given back when the connection ends.
- **Notifications.** Alerts are created on the parent device itself. No push server is involved.
- **Journal and night log.** The list of the night's events (monitoring started, noise, crying, connection lost, battery) and the diagnostic log (battery, temperature, link state) stay on your devices. The journal is copied from the baby device to the paired parent devices over the encrypted link. The log leaves a device only when you export it yourself.
- **Pairing key.** Pairing creates a secret key shared by your devices. It is stored in the Keychain of each device and is never sent anywhere.

## What goes through iCloud

So that your devices can find each other away from home, each one writes a small record to Apple's iCloud (the CloudKit public database of the app). The record holds:

- the device's current network addresses;
- for alerts when no direct link can be made: whether monitoring is on, and its latest events.

These records are encrypted on your device with the pairing key before they leave it. Apple stores them, and neither Apple nor we can read them. Pictures and sound never go through iCloud. Apple handles iCloud data under its own privacy policy: <https://www.apple.com/legal/privacy/>.

Without an iCloud account the app still works on your home Wi-Fi, and nothing is written to iCloud.

## What we collect

Nothing. The developer of NuzzleCam has no access to your pictures, your sound, your journal, your network addresses or your identity.

## Deleting your data

Unpairing the devices in the app's settings erases the journal and the pairing key from the device. Deleting the app erases everything it stored on the device. The encrypted records in iCloud cannot be read without the pairing key, so they are unusable once the key is erased.

## Children

The app is meant for parents and carers. It is not directed at children and collects no information from them.

## Changes and contact

Changes to this policy are published on this page. For any question, open an issue at <https://github.com/guillim/babyphone/issues>.

---

# Politique de confidentialité de NuzzleCam

Dernière mise à jour : 26 novembre 2026

NuzzleCam est un babyphone fait de deux ou trois de vos propres iPhone ou iPad. Cette page explique ce que deviennent vos données quand vous l'utilisez.

## En bref

- Nous n'avons aucun serveur. Nous ne recevons ni image, ni son, ni information sur vous.
- Il n'y a ni compte, ni publicité, ni mesure d'audience, ni suivi.
- L'image et le son vont directement de l'appareil placé dans la chambre à celui du parent, chiffrés entre les deux.

## Ce que l'app utilise sur vos appareils

- **Caméra et micro.** L'appareil placé dans la chambre filme et écoute la pièce, et envoie cela en direct aux appareils parents que vous lui avez associés. L'appareil parent n'utilise sa caméra que pour scanner le code d'appairage, et son micro que pendant que vous tenez le bouton pour parler. L'app n'enregistre ni l'image ni le son.
- **Réseau local.** À la maison, les appareils se trouvent sur votre Wi-Fi et se connectent directement. L'appareil de la chambre peut demander à votre box d'ouvrir un port, pour rester joignable de l'extérieur. Le port est rendu quand la connexion se termine.
- **Notifications.** Les alertes sont créées sur l'appareil parent lui-même. Aucun serveur de notifications n'intervient.
- **Journal et relevé de la nuit.** La liste des événements de la nuit (surveillance démarrée, bruit, pleurs, connexion perdue, batterie) et le relevé de diagnostic (batterie, température, état de la liaison) restent sur vos appareils. Le journal est copié de l'appareil bébé vers les appareils parents associés, par la liaison chiffrée. Le relevé ne quitte un appareil que si vous l'exportez vous-même.
- **Clé d'appairage.** L'appairage crée une clé secrète partagée par vos appareils. Elle est conservée dans le trousseau de chaque appareil et n'est jamais envoyée ailleurs.

## Ce qui passe par iCloud

Pour que vos appareils se retrouvent hors de la maison, chacun écrit une petite fiche dans iCloud, chez Apple (la base publique CloudKit de l'app). La fiche contient :

- les adresses réseau actuelles de l'appareil ;
- pour les alertes quand aucune liaison directe n'est possible : si la surveillance est active, et ses derniers événements.

Ces fiches sont chiffrées sur votre appareil avec la clé d'appairage avant d'en sortir. Apple les stocke, et ni Apple ni nous ne pouvons les lire. L'image et le son ne passent jamais par iCloud. Apple traite les données iCloud selon sa propre politique de confidentialité : <https://www.apple.com/fr/legal/privacy/>.

Sans compte iCloud, l'app fonctionne quand même sur votre Wi-Fi, et rien n'est écrit dans iCloud.

## Ce que nous collectons

Rien. Le développeur de NuzzleCam n'a accès ni à vos images, ni à votre son, ni à votre journal, ni à vos adresses réseau, ni à votre identité.

## Supprimer vos données

Dissocier les appareils dans les réglages de l'app efface le journal et la clé d'appairage de l'appareil. Supprimer l'app efface tout ce qu'elle a stocké sur l'appareil. Les fiches chiffrées dans iCloud sont illisibles sans la clé d'appairage : elles deviennent inutilisables dès que la clé est effacée.

## Enfants

L'app s'adresse aux parents et aux personnes qui gardent un enfant. Elle ne s'adresse pas aux enfants et ne collecte aucune information les concernant.

## Modifications et contact

Les modifications de cette politique sont publiées sur cette page. Pour toute question, ouvrez un ticket sur <https://github.com/guillim/babyphone/issues>.
