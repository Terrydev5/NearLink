# NearLink Protocol

This document describes protocol version 2 as implemented by the Apple and Android clients. It is a working interoperability specification, not a guarantee of compatibility with older builds.

## Transport and discovery

- Devices advertise and browse the DNS-SD / Bonjour service `_nearlink._tcp` on the local network.
- The TXT record contains `deviceId` (UUID), `platform`, and `protocolVersion`.
- The control channel is a WebSocket connection over TCP.
- An offered file is delivered through a separate TCP connection. The sender chooses and advertises a temporary port in the file offer.

Only devices with the same protocol version should communicate. The current version is `2`.

## Control envelope

Every WebSocket message is UTF-8 JSON with this shape. `timestamp` is Unix time in milliseconds and identifiers are UUID strings.

```json
{
  "version": 2,
  "type": "text_message",
  "messageID": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": 1760000000000,
  "payload": {}
}
```

Supported message types are `hello`, `text_message`, `file_offer`, `file_accept`, `file_reject`, `transfer_start`, `transfer_progress`, `transfer_complete`, `transfer_cancel`, `heartbeat`, `heartbeat_ack`, `ack`, and `error`.

`hello.payload.device` includes `id`, `name`, `platform`, and `protocolVersion`. A text message uses `payload.text` and may include `payload.senderID` so a receiver can identify its peer while the initial hello frame is still being handled.

## File transfer

1. The sender calculates the file's SHA-256 digest, opens a temporary TCP listener, generates a random one-time token, and sends `file_offer`.
2. `file_offer.payload.transfer` contains `id`, `fileName`, `fileSize`, `checksum`, optional `mimeType`, `streamPort`, `streamToken`, and `streamTokenExpiresAt`.
3. The receiver accepts with `file_accept` or declines with `file_reject`. Both carry `transferID` and `receivedBytes`.
4. Before the receiver reads file bytes from the TCP connection, it sends the ASCII stream token followed by a newline (`\n`). The sender serves only an authenticated client.
5. The receiver writes the stream in 256 KiB chunks, calculates SHA-256, and rejects the result if it differs from `checksum`. A successful receiver sends `transfer_complete`.

Both clients reject incoming offers with negative sizes or sizes above 2 GiB (2,147,483,648 bytes), malformed SHA-256 digests, insufficient free storage, or more than ten concurrent receives. Admission accounts for other active receives and a 512 MiB free-space reserve. A receiver warns locally when projected remaining storage is below 2 GiB. iOS also reserves room for an automatic Photos copy where applicable.

The data stream must contain exactly `fileSize` bytes. Receivers reject excess bytes before writing them, reject premature EOF, and verify the digest before publishing the file. Failures remove partial files/pending media and send `file_reject` when the control connection is available. Receive limits are local policy and do not change protocol version 2.

ACK frames use the complete control envelope, including a fresh `messageID` and millisecond `timestamp`. `payload.messageID` identifies the acknowledged message.

Tokens are URL-safe, 256-bit random values and expire after two minutes in the current implementation. They authenticate the temporary data connection; they do **not** encrypt control messages or file contents.

## Compatibility and change policy

Any incompatible wire-format change must increase `version`. Additive optional fields may remain within a protocol version only when both clients safely ignore fields they do not know. Update this document and add cross-platform test vectors before changing the wire format.
