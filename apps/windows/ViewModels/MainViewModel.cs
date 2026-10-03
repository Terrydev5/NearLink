using Microsoft.UI.Xaml;
using NearLink.Core;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace NearLink.Windows;

public sealed record DeviceRow(Guid Id, string Name, string Detail, bool Online);
public sealed class ConversationRow : INotifyPropertyChanged
{
    private TransferRecord? _transfer;
    public Guid Id { get; }
    public Guid? TransferID { get; }
    public string Heading { get; }
    public string Body { get; }
    public string Detail => _transfer == null ? "" :
        $"{(_transfer.Incoming ? "Receiving" : "Sending")} · {_transfer.State} · {Size(_transfer.CompletedBytes)} / {Size(_transfer.FileSize)}"
        + (_transfer.Error == null ? "" : $"\n{_transfer.Error}");
    public double Progress => _transfer is { FileSize: > 0 } t ? Math.Clamp(t.CompletedBytes * 100.0 / t.FileSize, 0, 100)
        : _transfer?.State == TransferState.Completed ? 100 : 0;
    public Visibility TransferVisibility => TransferID.HasValue ? Visibility.Visible : Visibility.Collapsed;
    public Visibility CancelVisibility => _transfer is { IsTerminal: false } ? Visibility.Visible : Visibility.Collapsed;
    public Visibility OpenVisibility => _transfer is { State: TransferState.Completed, LocalPath: not null } ? Visibility.Visible : Visibility.Collapsed;
    public string? LocalPath => _transfer?.LocalPath;
    public event PropertyChangedEventHandler? PropertyChanged;
    public ConversationRow(ConversationEntry entry, string peerName, TransferRecord? transfer)
    {
        Id = entry.Id;
        TransferID = entry.TransferID;
        Heading = $"{(entry.Incoming ? peerName : "You")} · {LocalTime(entry.Timestamp)}";
        Body = transfer?.FileName ?? entry.Text ?? "File transfer";
        _transfer = transfer;
    }
    public void Update(TransferRecord transfer)
    {
        if (_transfer == transfer) return;
        _transfer = transfer;
        PropertyChanged?.Invoke(this, new(null));
    }
    private static string Size(long bytes) => bytes >= 1024 * 1024 * 1024 ? $"{bytes / (1024.0 * 1024 * 1024):F2} GiB"
        : bytes >= 1024 * 1024 ? $"{bytes / (1024.0 * 1024):F1} MiB" : $"{bytes / 1024.0:F1} KiB";
    private static string LocalTime(long timestamp)
    {
        try { return DateTimeOffset.FromUnixTimeMilliseconds(timestamp).ToLocalTime().ToString("g"); }
        catch (ArgumentException) { return "Unknown time"; }
    }
}

public sealed class MainViewModel : INotifyPropertyChanged, IAsyncDisposable
{
    private readonly NearLinkClient _client;
    private readonly Action<Action> _dispatch;
    private Guid? _selectedID;
    private string _draft = "";
    private bool _sending;
    private string _notice = "";
    private string _status = "Starting…";
    private bool _refreshQueued;
    private readonly object _refreshGate = new();
    public ObservableCollection<DeviceRow> Devices { get; } = [];
    public ObservableCollection<ConversationRow> Conversation { get; } = [];
    public string LocalName => _client.LocalDevice.Name;
    public string ReceiveDirectory { get; }
    public string Status { get => _status; private set { _status = value; Notify(); } }
    public string Notice { get => _notice; set { _notice = value; Notify(); Notify(nameof(HasNotice)); } }
    public bool HasNotice => !string.IsNullOrEmpty(Notice);
    public string Draft { get => _draft; set { _draft = value; Notify(); Notify(nameof(CanSend)); } }
    public bool CanAttach => _selectedID.HasValue && Devices.Any(d => d.Id == _selectedID && d.Online);
    public bool CanSend => CanAttach && !_sending && !string.IsNullOrWhiteSpace(Draft);
    public string ConversationTitle => Devices.FirstOrDefault(d => d.Id == _selectedID)?.Name ?? "Select a nearby device";
    public string ConversationStatus => !_selectedID.HasValue ? "Messages and files stay on your devices"
        : CanAttach ? "Online" : "Offline · saved conversation";
    public Guid? SelectedID => _selectedID;
    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action? DevicesRefreshed;

    public MainViewModel(Action<Action> dispatch)
    {
        _dispatch = dispatch;
        ReceiveDirectory = Path.Combine(WindowsFolders.Downloads(), "NearLink", "Received");
        var state = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NearLink");
        _client = new(new(state, ReceiveDirectory));
        _client.Changed += QueueRefresh;
        _client.Notice += message => _dispatch(() => Notice = message);
        Refresh();
    }

    public async Task StartAsync()
    {
        try { await _client.StartAsync(); }
        catch (Exception error) { Notice = $"NearLink could not start: {error.Message}"; }
    }

    public void Select(Guid? id)
    {
        if (_selectedID == id) return;
        _selectedID = id;
        Draft = "";
        Conversation.Clear();
        Refresh();
    }

    private void QueueRefresh()
    {
        lock (_refreshGate) { if (_refreshQueued) return; _refreshQueued = true; }
        _dispatch(() =>
        {
            lock (_refreshGate) _refreshQueued = false;
            Refresh();
        });
    }

    private void Refresh()
    {
        var snapshot = _client.Snapshot();
        Status = snapshot.Status;
        var profiles = snapshot.KnownDevices.ToDictionary(d => d.Id);
        foreach (var device in snapshot.OnlineDevices) profiles[device.Id] = device.Profile;
        var online = snapshot.OnlineDevices.Select(d => d.Id).ToHashSet();
        var rows = profiles.Values.OrderByDescending(p => online.Contains(p.Id)).ThenBy(p => p.Name)
            .Select(p => new DeviceRow(p.Id, p.Name, $"{p.Platform} · {(online.Contains(p.Id) ? "Online" : "Offline")}", online.Contains(p.Id))).ToArray();
        if (!Devices.SequenceEqual(rows))
        {
            Devices.Clear();
            foreach (var row in rows) Devices.Add(row);
            DevicesRefreshed?.Invoke();
        }
        var transfers = snapshot.Transfers.ToDictionary(t => t.Id);
        var entries = snapshot.Entries.Where(e => e.PeerID == _selectedID).OrderBy(e => e.Timestamp).ToArray();
        var visibleIDs = entries.Select(e => e.Id).ToHashSet();
        for (var i = Conversation.Count - 1; i >= 0; i--)
            if (!visibleIDs.Contains(Conversation[i].Id)) Conversation.RemoveAt(i);
        foreach (var entry in entries)
        {
            var transfer = entry.TransferID is Guid id ? transfers.GetValueOrDefault(id) : null;
            var existing = Conversation.FirstOrDefault(r => r.Id == entry.Id);
            if (existing == null) Conversation.Add(new(entry, profiles.GetValueOrDefault(entry.PeerID)?.Name ?? "Peer", transfer));
            else if (transfer != null) existing.Update(transfer);
        }
        Notify(nameof(ConversationTitle)); Notify(nameof(ConversationStatus));
        Notify(nameof(CanAttach)); Notify(nameof(CanSend));
    }

    public async Task SendAsync()
    {
        if (!CanSend || _selectedID is not Guid peerID) return;
        var text = Draft;
        _sending = true; Notify(nameof(CanSend));
        try
        {
            await _client.SendTextAsync(peerID, text);
            if (_selectedID == peerID && Draft == text) Draft = "";
        }
        catch (Exception error) { Notice = $"Message was not confirmed. Your draft is kept. {error.Message}"; }
        finally { _sending = false; Notify(nameof(CanSend)); }
    }

    public async Task SendFilesAsync(IEnumerable<string> paths)
    {
        if (!CanAttach || _selectedID is not Guid peerID) return;
        var selected = paths.ToArray();
        if (selected.Length > 10) { Notice = "Choose at most 10 files at a time."; return; }
        await Task.WhenAll(selected.Select(async path =>
        {
            try { await _client.SendFileAsync(peerID, path); }
            catch (Exception error) { _dispatch(() => Notice = $"Could not send {Path.GetFileName(path)}: {error.Message}"); }
        }));
    }
    public Task CancelAsync(Guid id) => _client.CancelTransferAsync(id);
    public void RefreshDiscovery() => _client.RefreshDiscovery();
    private void Notify([CallerMemberName] string? property = null) => PropertyChanged?.Invoke(this, new(property));
    public ValueTask DisposeAsync() => _client.DisposeAsync();
}
