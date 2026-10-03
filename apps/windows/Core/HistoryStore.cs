using System.Text.Json;

namespace NearLink.Core;

public enum TransferState { Preparing, Waiting, Transferring, Verifying, AwaitingConfirmation, Completed, Unconfirmed, Failed, Cancelled }
public sealed record TransferRecord(Guid Id, Guid PeerID, string FileName, long FileSize, bool Incoming,
    TransferState State, long CompletedBytes = 0, string? LocalPath = null, string? Error = null)
{
    public bool IsTerminal => State is TransferState.Completed or TransferState.Unconfirmed
        or TransferState.Failed or TransferState.Cancelled;
}
public sealed record ConversationEntry(Guid Id, Guid PeerID, long Timestamp, bool Incoming,
    string? Text = null, Guid? TransferID = null);
public sealed record History(DeviceProfile[] Devices, ConversationEntry[] Entries, TransferRecord[] Transfers);
public sealed record ClientSnapshot(NearbyDevice[] OnlineDevices, DeviceProfile[] KnownDevices,
    ConversationEntry[] Entries, TransferRecord[] Transfers, string Status);

public sealed class HistoryStore
{
    private readonly string _directory;
    private readonly object _gate = new();
    public HistoryStore(string directory) { _directory = directory; Directory.CreateDirectory(directory); }

    public DeviceProfile LoadIdentity()
    {
        lock (_gate)
        {
            var path = Path.Combine(_directory, "device-id.txt");
            if (File.Exists(path))
            {
                if (!Guid.TryParse(File.ReadAllText(path), out var existing) || existing == Guid.Empty)
                    throw new InvalidDataException("The saved device identity is invalid. Restore or remove device-id.txt.");
                return new(existing, $"Windows-{Environment.MachineName}", "windows");
            }
            var id = Guid.NewGuid();
            AtomicWrite(path, id.ToString());
            return new(id, $"Windows-{Environment.MachineName}", "windows");
        }
    }

    public History Load()
    {
        lock (_gate)
        {
            var path = Path.Combine(_directory, "history.json");
            if (!File.Exists(path)) return new([], [], []);
            var history = JsonSerializer.Deserialize<History>(File.ReadAllText(path), Protocol.Json)
                ?? throw new InvalidDataException("Invalid conversation history.");
            if (history.Devices == null || history.Entries == null || history.Transfers == null
                || history.Entries.Any(e => e.Timestamp <= 0 || e.Timestamp > DateTimeOffset.MaxValue.ToUnixTimeMilliseconds()))
                throw new InvalidDataException("Invalid conversation history fields.");
            // Process restart cannot resume sockets. Keep the real saved path; never guess by filename.
            return history with { Transfers = history.Transfers.Select(t => t.IsTerminal ? t :
                t with { State = TransferState.Failed, Error = "The app stopped before this transfer finished." }).ToArray() };
        }
    }

    public void Save(History history)
    {
        lock (_gate) AtomicWrite(Path.Combine(_directory, "history.json"), JsonSerializer.Serialize(history, Protocol.Json));
    }

    private static void AtomicWrite(string path, string contents)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, contents);
            File.Move(temporary, path, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
