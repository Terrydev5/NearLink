# Security policy

## Supported versions

NearLink is pre-1.0 software. Security fixes are made against the latest code on `main`; older snapshots are not supported.

## Current security boundary

Protocol version 2 uses a random, single-use file-stream token that expires after two minutes, plus SHA-256 verification after a file is received. This limits unauthorised use of a temporary file listener and detects file corruption.

NearLink does **not** currently encrypt its control or file transports and does not authenticate or pair devices. A person able to observe or alter local-network traffic may be able to read, replay, or forge protocol traffic. Do not use the project for sensitive data, and do not treat the file-stream token as a replacement for TLS or peer verification.

Android presents incoming file offers for user approval. The current Apple client begins receiving a file offer automatically; Apple users should therefore treat every visible nearby peer as trusted.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub private vulnerability reporting if it is enabled for the repository; otherwise, contact the repository owner privately through the contact method listed on the GitHub profile. Include:

- a description of the issue and its impact;
- reproduction steps or a minimal proof of concept;
- affected platform and version; and
- any suggested mitigation.

Do not include real user files, private keys, passwords, or live transfer tokens in a report. Please allow a reasonable time for acknowledgement and remediation before public disclosure.
