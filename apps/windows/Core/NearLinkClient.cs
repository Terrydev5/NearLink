using System.Net;
using System.Net.WebSockets;
using System.Text.Json;
using System.Collections.Concurrent;

namespace NearLink.Core;

public sealed class NearLinkClient : IAsyncDisposable
{
    private readonly object _gate = new();
    private readonly ClientOptions _options;
    private readonly HistoryStore _store;
    private readonly CancellationTokenSource _stop = new();
    private readonly ControlServer _server = new();
    private readonly FileTransfers _files;
    private readonly Dictionary<Guid, NearbyDevice> _online = [];
    private readonly Dictionary<Guid, DeviceProfile> _known = [];
    private readonly Dictionary<Guid, TransferRecord> _transfers = [];
    private readonly List<ConversationEntry> _entries = [];
    private readonly HashSet<PeerSession> _sessions = [];
    private readonly Dictionary<Guid, (NearbyDevice Endpoint, PeerSession Session)> _outgoing = [];
    private readonly ConcurrentDictionary<Guid, SemaphoreSlim> _connectGates = new();
    private readonly bool _historyWritable = true;
    private NearbyDiscovery? _discovery;
    private Task? _startTask;
    private string _status = "Starting…";
    private int _disposed;
    public DeviceProfile LocalDevice { get; }
    public int ControlPort => _server.Port;
    public event Action? Changed;
    public event Action<string>? Notice;

    public NearLinkClient(ClientOptions options)
    {
        _options = options;
        _store = new(options.StateDirectory);
        LocalDevice = _store.LoadIdentity();
        try
        {
            var history = _store.Load();
            foreach (var device in history.Devices) _known[device.Id] = device;
            _entries.AddRange(history.Entries.TakeLast(5000));
            foreach (var transfer in history.Transfers) _transfers[transfer.Id] = transfer;
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException)
        {
            _historyWritable = false;
            _status = $"History could not be loaded and will be preserved: {error.Message}";
        }
        _files = new(options, _stop.Token);
        _files.RestoreHistory(_transfers.Values);
        _files.Updated += TransferUpdated;
        _files.Notice += message => Notice?.Invoke(message);
    }

    public ClientSnapshot Snapshot()
    {
        lock (_gate) return new(_online.Values.ToArray(), _known.Values.ToArray(),
            _entries.ToArray(), _transfers.Values.ToArray(), _status);
    }

    public Task StartAsync()
    {
        lock (_gate) return _startTask ??= StartCoreAsync();
    }

    private async Task StartCoreAsync()
    {
        await Task.Yield();
        await _server.StartAsync(_options.ControlPort, AcceptAsync, _stop.Token);
        if (_options.EnableDiscovery)
        {
            _discovery = new(LocalDevice, _server.Port);
            _discovery.DevicesChanged += UpdatePeers;
            _discovery.Error += message => SetStatus(message);
            try { _discovery.Start(); }
            catch (Exception error) { SetStatus($"Discovery could not start: {error.Message}"); throw; }
        }
        SetStatus("Searching nearby devices");
        if (!_historyWritable) Notice?.Invoke("Local history could not be loaded. The existing history file is preserved; new history will not be saved.");
    }

    public void RefreshDiscovery() => _discovery?.Refresh();

    // Endpoint updates always replace the current route; selection is a stable ID, never a cached device object.
    public void UpdatePeers(IReadOnlyList<NearbyDevice> devices)
    {
        List<PeerSession> obsolete = [];
        lock (_gate)
        {
            _online.Clear();
            foreach (var device in devices.Where(d => d.Id != LocalDevice.Id && d.Profile.ProtocolVersion == Protocol.Version))
            {
                _online[device.Id] = device;
                if (_known.ContainsKey(device.Id)) _known[device.Id] = device.Profile;
            }
            foreach (var entry in _outgoing.ToArray())
            {
                if (!_online.TryGetValue(entry.Key, out var current) || !SameEndpoint(entry.Value.Endpoint, current))
                {
                    _outgoing.Remove(entry.Key);
                    obsolete.Add(entry.Value.Session);
                }
            }
            _status = _online.Count == 0 ? "Searching nearby devices" : $"{_online.Count} nearby device(s)";
        }
        foreach (var session in obsolete) session.Stop();
        Changed?.Invoke();
    }

    private static bool SameEndpoint(NearbyDevice a, NearbyDevice b) =>
        a.Host == b.Host && a.Port == b.Port
        && (a.AlternativeHosts ?? []).SequenceEqual(b.AlternativeHosts ?? []);

    private async Task AcceptAsync(WebSocket socket, string remoteHost, CancellationToken request)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(request, _stop.Token);
        await using var session = CreateSession(socket, remoteHost, null, lifetime.Token);
        try
        {
            var receiving = session.RunAsync();
            await session.SendAsync(Protocol.Message("hello", new HelloPayload(LocalDevice)), lifetime.Token);
            await receiving;
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or WebSocketException)
        { session.Stop(); }
    }

    private PeerSession CreateSession(WebSocket socket, string host, Guid? peerID, CancellationToken lifetime)
    {
        var session = new PeerSession(socket, host, peerID, lifetime) { MessageReceived = HandleMessageAsync };
        session.Closed += closed =>
        {
            lock (_gate)
            {
                _sessions.Remove(closed);
                foreach (var entry in _outgoing.Where(p => ReferenceEquals(p.Value.Session, closed)).ToArray())
                    _outgoing.Remove(entry.Key);
            }
            _files.ConnectionClosed(closed);
        };
        session.Error += message => SetStatus(message);
        lock (_gate) _sessions.Add(session);
        return session;
    }

    private async Task<PeerSession> ConnectionAsync(Guid peerID, CancellationToken token)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(token, _stop.Token);
        var connectGate = _connectGates.GetOrAdd(peerID, _ => new(1, 1));
        await connectGate.WaitAsync(lifetime.Token);
        try
        {
            NearbyDevice target;
            lock (_gate)
            {
                target = _online.GetValueOrDefault(peerID) ?? throw new IOException("This device is offline.");
                if (_outgoing.TryGetValue(peerID, out var existing) && existing.Session.IsOpen && SameEndpoint(existing.Endpoint, target))
                    return existing.Session;
            }
            Exception? lastError = null;
            foreach (var host in new[] { target.Host }.Concat(target.AlternativeHosts ?? []).Distinct())
            {
                var socket = new ClientWebSocket();
                // A local-network peer must never be routed through the machine's HTTP proxy.
                socket.Options.Proxy = null;
                try
                {
                    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                    timeout.CancelAfter(_options.ConnectTimeout);
                    // Discovery supplies numeric hosts; UriBuilder handles brackets for IPv6.
                    if (!IPAddress.TryParse(host, out _)) throw new IOException("Discovery did not provide an IP address.");
                    await socket.ConnectAsync(new UriBuilder("ws", host, target.Port, "/").Uri, timeout.Token);
                    PeerSession session;
                    lock (_gate)
                    {
                        if (!_online.TryGetValue(peerID, out var current) || !SameEndpoint(target, current))
                            throw new IOException("The device address changed while connecting. Please retry.");
                        session = CreateSession(socket, host, peerID, _stop.Token);
                        _outgoing[peerID] = (target, session);
                        _known[peerID] = target.Profile;
                    }
                    _ = RunOutgoingAsync(session);
                    await session.SendAsync(Protocol.Message("hello", new HelloPayload(LocalDevice)), lifetime.Token);
                    Publish(persist: true);
                    return session;
                }
                catch (Exception error) when (error is IOException or WebSocketException or OperationCanceledException)
                {
                    socket.Dispose();
                    lifetime.Token.ThrowIfCancellationRequested();
                    lastError = error;
                }
            }
            throw new IOException("Could not connect to the nearby device. Check its network and firewall.", lastError);
        }
        finally { connectGate.Release(); }
    }

    private static async Task RunOutgoingAsync(PeerSession session)
    {
        await using (session) { await session.RunAsync(); }
    }

    public async Task SendTextAsync(Guid peerID, string text, CancellationToken token = default)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        var session = await ConnectionAsync(peerID, token);
        var envelope = Protocol.Message("text_message", new TextPayload(text.Trim(), LocalDevice.Id));
        await session.SendConfirmedAsync(envelope, _options.MessageAckTimeout, token);
        AddMessage(new(envelope.MessageID, peerID, envelope.Timestamp, false, text.Trim()));
    }

    public async Task SendFileAsync(Guid peerID, string path, CancellationToken token = default)
    {
        // Use our outbound control connection. Android currently handles file offers on its server route.
        var session = await ConnectionAsync(peerID, token);
        await _files.SendAsync(session, path, token);
    }
    public Task CancelTransferAsync(Guid id) => _files.CancelAsync(id);

    private Task HandleMessageAsync(PeerSession session, ControlEnvelope envelope)
    {
        if (session.PeerID is Guid knownID)
        {
            lock (_gate)
                if (_online.TryGetValue(knownID, out var found))
                    session.ApplyInterfaceScope(new[] { found.Host }.Concat(found.AlternativeHosts ?? []));
        }
        switch (envelope.Type)
        {
            case "hello":
                var profile = Protocol.Payload<HelloPayload>(envelope).Device;
                if (profile.Id == LocalDevice.Id || profile.ProtocolVersion != Protocol.Version || string.IsNullOrWhiteSpace(profile.Name))
                    throw new InvalidDataException("Invalid peer hello.");
                session.Identify(profile.Id);
                lock (_gate) _known[profile.Id] = profile;
                Publish(persist: true);
                break;
            case "text_message":
                var text = Protocol.Payload<TextPayload>(envelope);
                if (session.PeerID == null && text.SenderID is Guid sender) session.Identify(sender);
                if (session.PeerID is not Guid peerID || text.Text == null) throw new InvalidDataException("Message has no peer identity.");
                AddMessage(new(envelope.MessageID, peerID, envelope.Timestamp, true, text.Text));
                break;
            default:
                return _files.HandleAsync(session, envelope);
        }
        return Task.CompletedTask;
    }

    private void AddMessage(ConversationEntry entry)
    {
        lock (_gate)
        {
            if (_entries.Any(e => e.Id == entry.Id)) return;
            _entries.Add(entry);
            TrimHistory();
        }
        Publish(persist: true);
    }

    private void TransferUpdated(TransferRecord transfer)
    {
        bool first;
        lock (_gate)
        {
            first = !_transfers.ContainsKey(transfer.Id);
            _transfers[transfer.Id] = transfer;
            if (first) _entries.Add(new(Guid.NewGuid(), transfer.PeerID, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                transfer.Incoming, TransferID: transfer.Id));
            TrimHistory();
        }
        Publish(persist: first || transfer.IsTerminal);
    }

    private void TrimHistory()
    {
        // Keep active rows; only completed history is eligible for eviction.
        while (_entries.Count > 5000)
        {
            var index = _entries.FindIndex(e => e.TransferID == null || !_transfers.TryGetValue(e.TransferID.Value, out var t) || t.IsTerminal);
            if (index < 0) break;
            if (_entries[index].TransferID is Guid id) _transfers.Remove(id);
            _entries.RemoveAt(index);
        }
    }

    private void Publish(bool persist)
    {
        string? failure = null;
        if (persist && _historyWritable)
        {
            lock (_gate)
            {
                try { _store.Save(new(_known.Values.ToArray(), _entries.ToArray(), _transfers.Values.ToArray())); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { failure = $"Could not save local history: {error.Message}"; }
            }
        }
        Changed?.Invoke();
        if (failure != null) Notice?.Invoke(failure);
    }
    private void SetStatus(string message) { lock (_gate) _status = message; Changed?.Invoke(); }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        _stop.Cancel();
        if (_startTask != null) { try { await _startTask; } catch { /* Start failure is already surfaced to the caller. */ } }
        if (_discovery != null) await _discovery.DisposeAsync();
        await _files.DisposeAsync();
        PeerSession[] sessions;
        lock (_gate) sessions = _sessions.ToArray();
        foreach (var session in sessions) session.Stop();
        foreach (var session in sessions) await session.DisposeAsync();
        await _server.DisposeAsync();
    }
}
