# NearLink

NearLink is an experimental local-network file and message transfer application for Apple and Android devices. It has no account or cloud relay: nearby peers find one another with Bonjour / DNS-SD, use WebSocket for control messages, and use a temporary TCP stream for file data.

## Current status

- Apple: iPhone and macOS discovery, text messaging, sending files, and receiving files.
- Android: Kotlin + Jetpack Compose client with discovery, text messaging, sending files, and receiving files.

File transfers use SHA-256 verification and a short-lived, one-time token for the TCP stream. This reduces accidental or opportunistic use of the temporary file port, but it is not end-to-end encryption and does not authenticate a peer. Use the app only with peers and networks you trust.

## Platform support

| Platform | Client | Status |
| --- | --- | --- |
| iOS | SwiftUI | Experimental |
| macOS | SwiftUI | Experimental |
| Android | Kotlin + Jetpack Compose | Experimental |

Windows is not included in this release.

## Repository layout

```text
apps/apple/    iOS + macOS SwiftUI application
apps/android/  Android Studio / Kotlin application
docs/          public project and GitHub preparation notes
```

## Build and test

Open `apps/apple/NearLink.xcodeproj` in a current Xcode release and select a physical iPhone, iPad, or Mac target.

On macOS, run `zsh apps/apple/scripts/test-device-history.sh` to check saved-device persistence, offline history access, reconnection, identity migration, and offline send guards using isolated test storage.

Open `apps/android` in Android Studio with Android SDK 35 and JDK 17. The debug APK can also be built from that directory with:

```bash
./gradlew :app:assembleDebug
```

Test discovery, messaging, normal file transfer, rejected unauthenticated connections, expired transfer tokens, and received-file integrity on at least two physical devices connected to the same local network. Emulators and simulators are not a substitute for mDNS and peer-to-peer testing.

All participants must run protocol version 2. Older builds are intentionally incompatible with v2 file offers.

## Security status

NearLink is an experimental local-network tool, not a secure messenger or a secure file vault. Control messages and file bytes are not yet encrypted, and devices are not yet paired or authenticated. Do not send private, confidential, or high-value data through NearLink.

Android currently presents incoming file offers for user acceptance or rejection. The current Apple client starts receiving an offer automatically, so Apple users must treat every visible nearby peer as trusted.

Protocol version 2 adds a 256-bit, one-time token to every temporary file stream. The token expires after two minutes and prevents a client that lacks the offer from reading file bytes. It does not protect against an attacker who can observe or alter local-network traffic.

## Privacy

See [Privacy and security](docs/privacy.md) for the data stored locally, permissions, and current security limitations. See [Protocol](docs/protocol.md) for the cross-platform wire format.

## Roadmap

- Add automated cross-platform protocol test vectors and continuous integration.
- Improve cancellation, resuming, and recovery after interrupted transfers.
- Add verified device pairing, then encrypt and authenticate control and file transports before recommending NearLink for sensitive content.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) and open an issue before proposing a protocol-breaking change.

## License

NearLink is released under the [MIT License](LICENSE).
