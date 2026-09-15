# Contributing to NearLink

Thanks for considering a contribution.

## Before you start

- Search existing issues and pull requests before opening a new one.
- For a protocol or cross-platform behavior change, open an issue first. Describe compatibility implications, update `docs/protocol.md`, and test both Apple and Android implementations in the same pull request.
- Test changes on real devices connected to the same local network. Simulators and emulators do not reliably reproduce Bonjour/mDNS behavior.

## Pull requests

1. Create a focused branch from `main`.
2. Keep each pull request limited to one problem or feature.
3. Include build/test evidence and list the Apple/Android devices or OS versions used when networking behavior changes. For file protocol changes, test successful transfer, unauthorised stream rejection, token expiry, checksum failure, and cancellation where applicable.
4. Do not commit private keys, provisioning profiles, real configuration files, received user files, or build outputs.
5. Explain any user-visible change and update documentation where needed.
6. Report potential vulnerabilities privately as described in [SECURITY.md](SECURITY.md), rather than opening a public issue.

By submitting a contribution, you agree that it may be distributed under the repository's [MIT License](LICENSE).
