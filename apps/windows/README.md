# NearLink for Windows

Experimental Windows x64 client using .NET 10 and WinUI. It discovers protocol-v2 peers with DNS-SD, exchanges text over WebSocket, and transfers files over temporary TCP streams.

The 2026-10-03 review passed 18 portable core test groups on macOS and protocol-fixture checks with the Apple and Android codecs. Native Windows compilation, startup, firewall behavior, and real-device interoperability have not been verified by that review. This is source under development, not a release certification.

## Build and publish

Use a Windows x64 development environment with the .NET 10 SDK and Windows SDK 10.0.19041.0 or newer. The project targets Windows 10 build 19041 or later. `global.json` selects a .NET 10 SDK feature band; a runtime-only installation is insufficient for building.

From this directory, run PowerShell:

```powershell
dotnet run --project Tests/NearLink.Core.Tests.csproj -c Release
./scripts/publish.ps1
```

The default output is `artifacts/win-x64/`. Copy the entire directory to the test PC and launch `NearLink.Windows.exe`. The app is unpackaged and self-contained; it is not published as a single executable. The script also copies this README and the optional firewall helper into the output directory.

## Connect and transfer

1. Connect the participating devices to the same trusted local network and keep NearLink open.
2. Select an online peer, then send a message or attach up to ten files per selection.
3. Incoming offers are automatically checked and accepted; there is no per-file approval dialog. The maximum incoming file size is 2 GiB, with at most ten concurrent receives and a 512 MiB storage reserve.
4. Sender completion waits for the peer's `transfer_complete` receipt. `Unconfirmed` means local sending finished but the receiver's save was not confirmed; check the receiving device before retrying.
5. Use **Open received files** to inspect the destination directory. Removing or moving a file outside NearLink leaves its history entry intact.

Control messages and file contents are unencrypted. Devices are not paired or authenticated. Discovery and the selected conversation do not restrict who may send offers. Use trusted peers and networks.

## Local storage and networking

- Received files: the Windows known Downloads folder, under `NearLink\Received`. Redirected Downloads folders are resolved through the Windows known-folder API.
- Identity and history: `%LOCALAPPDATA%\NearLink\device-id.txt` and `history.json`. History records the actual published file path.
- Control listener: TCP 41820 by default.
- Discovery: multicast DNS on UDP 5353.
- File streams: dynamically allocated TCP ports. Opening only TCP 41820 is insufficient for receiving connections to outgoing file streams.

The app runs as a normal user. If Windows Firewall blocks discovery or transfers on a private test network, an administrator can explicitly run the helper from the published directory:

```powershell
./configure-firewall.ps1
```

From the source directory, pass the published executable instead:

```powershell
./scripts/configure-firewall.ps1 -Executable ./artifacts/win-x64/NearLink.Windows.exe
```

The helper creates inbound rules scoped to that executable, Private profiles and the local subnet; UDP is limited to port 5353. It does not disable the firewall. Moving the published directory requires updating the executable path in the rules.

## Portable tests

The `Core` and console `Tests` projects target `net10.0` and can run on macOS/Linux as well as Windows. They cover protocol envelopes, storage policy, verified publication, filenames, history, DNS cache behavior, and loopback WebSocket/TCP lifecycles.

```bash
dotnet run --project Tests/NearLink.Core.Tests.csproj -c Release
```

Passing these tests does not validate WinUI, native Windows APIs, firewall configuration or real-network mDNS.

## Protocol fixture checks

On macOS, with .NET 10, Xcode, and the Android JDK/SDK configured, run the following from the **repository root**. Use a new temporary directory for generated fixtures:

```bash
nearlink_fixtures=$(mktemp -d)
dotnet run --project apps/windows/Tests/NearLink.Core.Tests.csproj -c Release -- \
  --export-fixtures "$nearlink_fixtures/windows.json"
zsh apps/windows/scripts/test-apple-interop.sh \
  "$nearlink_fixtures/windows.json" "$nearlink_fixtures/apple.json"
(
  cd apps/android
  NEARLINK_WINDOWS_FIXTURES="$nearlink_fixtures/windows.json" \
  NEARLINK_ANDROID_FIXTURES="$nearlink_fixtures/android.json" \
  NEARLINK_ACK_FIXTURE="$nearlink_fixtures/android-ack.json" \
  ./gradlew -I ../windows/scripts/android-interop.gradle :app:testDebugUnitTest --rerun-tasks
)
zsh apps/apple/scripts/test-transfer-safety.sh "$nearlink_fixtures/android-ack.json"
dotnet run --project apps/windows/Tests/NearLink.Core.Tests.csproj -c Release -- \
  --control-fixtures "$nearlink_fixtures/apple.json" \
  --control-fixtures "$nearlink_fixtures/android.json" \
  --ack-fixture "$nearlink_fixtures/android-ack.json"
```

These commands check production encoders/decoders and existing test fixtures. They do not run the three native clients against one another.

## Known gaps

The DNS cache currently retains an old IP after a cache-flush address update, which can delay reconnection. Apple/Android peers also retain their platform-specific completion, cancellation and address-handling limitations. See `docs/protocol.md` for cross-platform behavior and current limitations.

The repository's `.github/workflows/windows.yml` defines Windows core tests/publication and Apple codec checks. Verify actual workflow results before distributing a build; the local review did not establish that the remote workflow passed.
