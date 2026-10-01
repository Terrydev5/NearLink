# Security policy

## Supported versions

NearLink is pre-1.0 software. Security fixes are made against the latest code on `main`; older snapshots are not supported.

## Current security boundary

Protocol version 2 uses a random, single-use file-stream token with a two-minute authorization window. Receivers verify the exact byte count and SHA-256 digest before publishing a file. These checks limit unauthorised use of a temporary file listener and detect file corruption; token expiry is not an end-to-end transfer timeout or a guarantee that every connection has been released.

NearLink does **not** currently encrypt its control or file transports and does not authenticate or pair devices. A person able to observe or alter local-network traffic may be able to read, replay, or forge protocol traffic. Do not use the project for sensitive data, and do not treat the file-stream token as a replacement for TLS or peer verification.

Apple and Android automatically check incoming file offers and begin receiving those that pass validation and storage checks. Neither client asks for per-file approval. Selecting a conversation or seeing a peer in discovery is not an access-control allowlist; use NearLink only on networks and with peers you trust.

Both clients limit each incoming file to 2 GiB (2,147,483,648 bytes), allow at most ten concurrent receives, and budget to keep 512 MiB of storage free. They show a receiver-side notice when projected remaining space is below 2 GiB, and reject offers when space is insufficient. iOS also budgets for an additional Photos copy where applicable. These are disk-space safeguards, not RAM limits or peer authentication.

Files remain temporary or pending until size and checksum verification succeeds. Handled receive failures clean up temporary data. Cancellation, timeout handling, and recovery after interruption remain incomplete; see the implementation limitations in [the protocol document](docs/protocol.md#implementation-limitations).

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub private vulnerability reporting if it is enabled for the repository; otherwise, contact the repository owner privately through the contact method listed on the GitHub profile. Include:

- a description of the issue and its impact;
- reproduction steps or a minimal proof of concept;
- affected platform and version; and
- any suggested mitigation.

Do not include real user files, private keys, passwords, or live transfer tokens in a report. Please allow a reasonable time for acknowledgement and remediation before public disclosure.
