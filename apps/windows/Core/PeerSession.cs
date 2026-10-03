using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Net;

namespace NearLink.Core;

public sealed class PeerSession : IAsyncDisposable
{
    private readonly WebSocket _socket;
    private readonly CancellationTokenSource _stop;
    private readonly CancellationToken _token;
    private readonly SemaphoreSlim _sendGate = new(1, 1);
    private readonly ConcurrentDictionary<Guid, TaskCompletionSource> _acks = new();
    private readonly HashSet<Guid> _seen = [];
    private readonly Queue<Guid> _seenOrder = [];
    private Task? _run;
    private int _stopped;
    private int _disposed;
    public Guid? PeerID { get; private set; }
    public string RemoteHost { get; private set; }
    public bool IsOpen => !_stop.IsCancellationRequested && _socket.State == WebSocketState.Open;
    public Func<PeerSession, ControlEnvelope, Task>? MessageReceived { get; set; }
    public event Action<PeerSession>? Closed;
    public event Action<string>? Error;

    public PeerSession(WebSocket socket, string remoteHost, Guid? peerID, CancellationToken lifetime)
    {
        _socket = socket;
        RemoteHost = remoteHost;
        PeerID = peerID;
        _stop = CancellationTokenSource.CreateLinkedTokenSource(lifetime);
        _token = _stop.Token;
    }

    public void Identify(Guid peerID)
    {
        if (peerID == Guid.Empty || (PeerID.HasValue && PeerID != peerID))
            throw new InvalidDataException("Peer identity changed within one connection.");
        PeerID = peerID;
    }

    public void ApplyInterfaceScope(IEnumerable<string> discoveredHosts)
    {
        if (!IPAddress.TryParse(RemoteHost, out var remote) || !remote.IsIPv6LinkLocal || remote.ScopeId != 0) return;
        foreach (var host in discoveredHosts)
        {
            if (IPAddress.TryParse(host, out var candidate) && candidate.IsIPv6LinkLocal && candidate.ScopeId != 0
                && candidate.GetAddressBytes().SequenceEqual(remote.GetAddressBytes()))
            { RemoteHost = candidate.ToString(); return; }
        }
    }

    public Task RunAsync() => _run ??= ReceiveLoopAsync();

    public async Task SendAsync(ControlEnvelope message, CancellationToken cancellationToken = default)
    {
        var data = Protocol.Encode(message);
        if (data.Length > Protocol.MaximumControlBytes) throw new IOException("Message is too large.");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _token);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        await _sendGate.WaitAsync(timeout.Token);
        try
        {
            if (!IsOpen) throw new IOException("The control connection is closed.");
            // One send at a time per socket, including ACKs and heartbeat replies.
            await _socket.SendAsync(data.AsMemory(), WebSocketMessageType.Text, true, timeout.Token);
        }
        finally { _sendGate.Release(); }
    }

    public async Task SendConfirmedAsync(ControlEnvelope message, TimeSpan timeout, CancellationToken token)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_acks.TryAdd(message.MessageID, completion)) throw new InvalidOperationException("Duplicate message ID.");
        try
        {
            // Register before sending: a fast peer can ACK before SendAsync returns.
            await SendAsync(message, token);
            await completion.Task.WaitAsync(timeout, token);
        }
        finally { _acks.TryRemove(message.MessageID, out _); }
    }

    private async Task ReceiveLoopAsync()
    {
        var heartbeat = HeartbeatAsync();
        try
        {
            var buffer = new byte[16 * 1024];
            using var message = new MemoryStream();
            while (IsOpen)
            {
                var result = await _socket.ReceiveAsync(buffer.AsMemory(), _token);
                if (result.MessageType == WebSocketMessageType.Close) break;
                if (result.MessageType != WebSocketMessageType.Text) throw new InvalidDataException("Expected a JSON text frame.");
                if (message.Length + result.Count > Protocol.MaximumControlBytes) throw new InvalidDataException("Control message is too large.");
                message.Write(buffer, 0, result.Count);
                if (!result.EndOfMessage) continue;
                var envelope = Protocol.Decode(message.GetBuffer().AsSpan(0, (int)message.Length));
                message.SetLength(0);
                if (envelope.Type == "ack")
                {
                    var ack = Protocol.Payload<AckPayload>(envelope);
                    if (_acks.TryRemove(ack.MessageID, out var waiter)) waiter.TrySetResult();
                    continue;
                }
                if (envelope.Type == "heartbeat_ack") continue;
                if (envelope.Type == "heartbeat")
                {
                    await SendAsync(Protocol.Message("heartbeat_ack", new { }), _token);
                    continue;
                }
                if (_seen.Add(envelope.MessageID))
                {
                    _seenOrder.Enqueue(envelope.MessageID);
                    if (_seenOrder.Count > 2048) _seen.Remove(_seenOrder.Dequeue());
                    if (MessageReceived != null) await MessageReceived(this, envelope);
                }
                await SendAsync(Protocol.Ack(envelope.MessageID), _token);
            }
        }
        catch (OperationCanceledException) when (_stop.IsCancellationRequested) { }
        catch (Exception error) { Error?.Invoke($"Connection closed: {error.Message}"); }
        finally
        {
            Stop();
            foreach (var pair in _acks) pair.Value.TrySetException(new IOException("Connection closed before confirmation."));
            _acks.Clear();
            await heartbeat;
            Closed?.Invoke(this);
        }
    }

    private async Task HeartbeatAsync()
    {
        try
        {
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(12));
            while (await timer.WaitForNextTickAsync(_token))
                await SendAsync(Protocol.Message("heartbeat", new { }), _token);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { Error?.Invoke($"Heartbeat failed: {error.Message}"); Stop(); }
    }

    public void Stop()
    {
        if (Interlocked.Exchange(ref _stopped, 1) != 0) return;
        _stop.Cancel();
        _socket.Abort();
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        Stop();
        if (_run != null) await _run;
        _socket.Dispose();
        _stop.Dispose();
        // In-flight sends may still release the semaphore; its storage is reclaimed by GC.
    }
}
