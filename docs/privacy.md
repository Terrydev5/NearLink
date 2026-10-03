# Privacy and security

## Network use

NearLink is designed for direct transfers between devices on the same local network. It does not use an account, cloud relay, analytics service, or remote storage.

The app advertises a local Bonjour/DNS-SD service and exchanges device metadata needed for discovery: device ID, display name, platform, and protocol version. Message text and file metadata are sent to the selected nearby peer over the local network.

## Local storage

- Apple clients keep the local device ID, conversation history, and transfer history in app storage. Received files are saved in `Downloads` on macOS and the app's `Documents/NearLink/Received` area on iOS. Received photos and videos may additionally be saved to the Photos library after permission is granted.
- Android keeps conversation and transfer history in app-private shared preferences. On Android 10 and later, received media is saved in the corresponding public `NearLink` media collection; other files go to `Download/NearLink`. Earlier Android versions use the app's external-files area.
- Android also stores a rotating startup/crash diagnostic log in app-private storage. NearLink does not upload this log.
- Windows keeps `device-id.txt` and `history.json` in `%LOCALAPPDATA%\NearLink` and saves received files in the Windows known Downloads folder under `NearLink\Received`. History stores the actual published file path.

Android currently sets `allowBackup="true"` and has no explicit backup exclusion rules. System-managed backup or device migration may therefore include app preferences and identity; the absence of a NearLink cloud service does not mean that operating-system backup is disabled.

Incoming files are kept in temporary files or pending MediaStore entries until byte-count and SHA-256 verification succeeds. Handled receive failures remove the temporary data; this does not guarantee cleanup after a process is forcibly terminated.

## Automatic reception and storage checks

Apple, Android, and Windows automatically check incoming file offers and receive those that pass validation and storage checks. There is no per-file approval prompt. A low-storage notice informs the receiver; it is not a request to approve the transfer. Opening or selecting a conversation is not required to receive an offer.

The incoming-file limit is 2 GiB (2,147,483,648 bytes), with at most ten concurrent receives. Before accepting a file, the app accounts for active receive reservations and keeps a 512 MiB free-space reserve. It warns when projected remaining storage is below 2 GiB and rejects files if storage is insufficient. Available space is checked again during writing. iOS also budgets for an additional Photos copy where applicable. These checks concern local disk storage, not device RAM.

## Permissions

- Apple asks for local-network access to discover peers and make direct connections. It asks for Photos add-only access only when saving received media to Photos.
- Android declares network access and Wi-Fi multicast support. Startup requests nearby Wi-Fi devices access on Android 13+, and fine plus coarse location on Android 8–12; granting either location permission is sufficient, so approximate location works on Android 12. The app does not read coordinates. These permissions are requested for the current discovery implementation.
- Windows runs as a normal user. Its optional firewall helper requires administrator privileges to add executable-scoped rules for private local networks; the app itself does not automatically run that helper.

## Security limitations

Protocol version 2 transfers use a 256-bit token, intended for one-time use within two minutes, to authorize the temporary TCP data stream. Android ignores duplicate accepts while a send is active, but atomic token consumption and a post-read expiry check remain open. Received files are checked with SHA-256. These safeguards reduce accidental or unauthorized use of the temporary listener and detect corruption; they do not provide end-to-end encryption or authenticate the identity of the remote person. Because the control channel is currently plaintext, a local-network attacker who can observe traffic can also observe a token.

Automatic reception and the discovery list do not authenticate a sender or restrict reception to selected peers. Apple/Android timeout and cancellation cleanup remain incomplete. Windows implements separate transfer deadlines and active-socket cancellation, but forced-process recovery is not complete. See the [protocol limitations](protocol.md#implementation-limitations) for current behavior.

Use NearLink only on networks and with peers you trust. Do not send sensitive content until transport encryption and peer authentication are available. This project is experimental software and has not received an external security audit.
