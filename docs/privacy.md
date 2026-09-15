# Privacy and security

## Network use

NearLink is designed for direct transfers between devices on the same local network. It does not use an account, cloud relay, analytics service, or remote storage.

The app advertises a local Bonjour/DNS-SD service and exchanges device metadata needed for discovery: device ID, display name, platform, and protocol version. Message text and file metadata are sent to the selected nearby peer over the local network.

## Local storage

- Apple clients keep the local device ID, conversation history, and transfer history in app storage. Received files are saved in `Downloads` on macOS and the app's `Documents/NearLink/Received` area on iOS. Received photos and videos may additionally be saved to the Photos library after permission is granted.
- Android keeps conversation and transfer history in app-private shared preferences. On Android 10 and later, received media is saved in the corresponding public `NearLink` media collection; other files go to `Download/NearLink`. Earlier Android versions use the app's external-files area.

## Permissions

- Apple asks for local-network access to discover peers and make direct connections. It asks for Photos add-only access only when saving received media to Photos.
- Android requests network access, Wi-Fi multicast support, and nearby Wi-Fi devices access. Android 12 and earlier use fine location permission for nearby-device discovery, as required by the platform API.

## Security limitations

Protocol version 2 transfers use a 256-bit, one-time token to authorize the temporary TCP data stream. Tokens expire after two minutes, and received files are checked with SHA-256. These safeguards reduce accidental or unauthorized use of the temporary listener and detect corruption; they do not provide end-to-end encryption or authenticate the identity of the remote person. Because the control channel is currently plaintext, a local-network attacker who can observe traffic can also observe a token.

Android asks the user to accept or reject incoming file offers. The current Apple client starts receiving an incoming offer automatically, so Apple users should use NearLink only with visible nearby peers they trust.

Use NearLink only on networks and with peers you trust. Do not send sensitive content until transport encryption and peer authentication are available. This project is experimental software and has not received an external security audit.
