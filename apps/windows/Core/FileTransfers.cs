using Microsoft.AspNetCore.StaticFiles;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace NearLink.Core;

public sealed class FileTransfers : IAsyncDisposable
{
    private sealed class Work(TransferRecord record, PeerSession peer, CancellationToken lifetime)
    {
        public readonly object Gate = new();
        public TransferRecord Record = record;
        public readonly PeerSession Peer = peer;
        public readonly CancellationTokenSource Stop = CancellationTokenSource.CreateLinkedTokenSource(lifetime);
        public readonly TaskCompletionSource Accepted = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly TaskCompletionSource Confirmed = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TcpListener? Listener;
        public TcpClient? Socket;
        public Task Task = Task.CompletedTask;
        public string? CancellationReason;
        public TransferState CancellationState = TransferState.Cancelled;
        public bool Finished;
        public long LastProgressTick;
        public void Cancel(string reason, TransferState state = TransferState.Cancelled)
        {
            lock (Gate)
            {
                if (Finished || Record.IsTerminal) return;
                CancellationReason = reason;
                CancellationState = state;
                Stop.Cancel();
                Listener?.Stop();
                Socket?.Dispose();
            }
        }
    }

    private readonly object _gate = new();
    private readonly Dictionary<Guid, Work> _active = [];
    private readonly Dictionary<Guid, TransferRecord> _finished = [];
    private readonly ClientOptions _options;
    private readonly CancellationToken _lifetime;
    private readonly ReceiveBudget _budget;
    private readonly Func<long> _available;
    public event Action<TransferRecord>? Updated;
    public event Action<string>? Notice;

    public FileTransfers(ClientOptions options, CancellationToken lifetime)
    {
        _options = options;
        _lifetime = lifetime;
        Directory.CreateDirectory(options.ReceiveDirectory);
        _available = options.AvailableBytes ?? (() => IncomingFilePolicy.AvailableBytes(options.ReceiveDirectory));
        _budget = new(_available);
    }

    public int ActiveCount { get { lock (_gate) return _active.Count; } }
    public int ReservedReceives => _budget.Count;
    public void RestoreHistory(IEnumerable<TransferRecord> records)
    {
        lock (_gate) foreach (var record in records.TakeLast(2048)) _finished[record.Id] = record;
    }

    public Task SendAsync(PeerSession peer, string path, CancellationToken token = default)
    {
        if (peer.PeerID is not Guid id) throw new IOException("The peer is not identified.");
        var work = new Work(new(Guid.NewGuid(), id, Path.GetFileName(path), 0, false, TransferState.Preparing), peer, _lifetime);
        lock (_gate)
        {
            if (_active.Values.Count(w => !w.Record.Incoming) >= 10) throw new IOException("Too many outgoing files. Wait for current transfers.");
            _active.Add(work.Record.Id, work);
            work.Task = RunSendAsync(work, path, token);
        }
        return work.Task;
    }

    public Task HandleAsync(PeerSession peer, ControlEnvelope message)
    {
        if (peer.PeerID is not Guid peerID) throw new InvalidDataException("File message received before hello.");
        if (message.Type == "file_offer")
        {
            var descriptor = Protocol.Payload<FileOfferPayload>(message).Transfer;
            return StartReceiveAsync(peer, peerID, descriptor);
        }
        if (message.Type is not ("file_accept" or "file_reject" or "transfer_cancel" or "transfer_complete")) return Task.CompletedTask;
        var decision = Protocol.Payload<TransferDecision>(message);
        Work? work;
        lock (_gate) _active.TryGetValue(decision.TransferID, out work);
        if (work == null)
        {
            TransferRecord? late = null;
            lock (_gate)
            {
                if (message.Type == "transfer_complete" && _finished.TryGetValue(decision.TransferID, out var old)
                    && old.PeerID == peerID && !old.Incoming && old.State == TransferState.Unconfirmed
                    && old.FileSize == decision.ReceivedBytes)
                    _finished[old.Id] = late = old with { State = TransferState.Completed, Error = null };
            }
            if (late != null) Updated?.Invoke(late);
            return Task.CompletedTask;
        }
        if (work.Record.PeerID != peerID) return Task.CompletedTask;
        switch (message.Type)
        {
            case "file_accept" when !work.Record.Incoming && decision.ReceivedBytes == 0:
                work.Accepted.TrySetResult();
                break;
            case "transfer_complete" when !work.Record.Incoming && decision.ReceivedBytes == work.Record.FileSize:
                work.Confirmed.TrySetResult();
                break;
            case "file_reject": work.Cancel("The receiver rejected the file.", TransferState.Failed); break;
            case "transfer_cancel": work.Cancel("Cancelled by the other device."); break;
        }
        return Task.CompletedTask;
    }

    private async Task StartReceiveAsync(PeerSession peer, Guid peerID, TransferDescriptor descriptor)
    {
        if (descriptor == null) throw new InvalidDataException("Missing file offer.");
        Work? work = null;
        try
        {
            IncomingFilePolicy.Validate(descriptor.FileSize, descriptor.Checksum);
            if (descriptor.Id == Guid.Empty || string.IsNullOrWhiteSpace(descriptor.FileName)
                || descriptor.StreamPort is < 1 or > 65535 || !Protocol.ValidToken(descriptor.StreamToken)
                || descriptor.StreamTokenExpiresAt < DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
                || !IPAddress.TryParse(peer.RemoteHost, out _))
                throw new IOException("Invalid or expired file offer.");
            string? warning;
            lock (_gate)
            {
                if (_active.ContainsKey(descriptor.Id) || _finished.ContainsKey(descriptor.Id)) return;
                warning = _budget.Reserve(descriptor.Id, descriptor.FileSize);
                work = new(new(descriptor.Id, peerID, IncomingFilePolicy.SafeName(descriptor.FileName),
                    descriptor.FileSize, true, TransferState.Waiting), peer, _lifetime);
                _active.Add(descriptor.Id, work);
                work.Task = RunReceiveAsync(work, descriptor);
            }
            if (warning != null) Notice?.Invoke(warning);
        }
        catch (Exception error)
        {
            Notice?.Invoke($"Could not receive {IncomingFilePolicy.SafeName(descriptor.FileName)}: {error.Message}");
            await BestEffortAsync(peer, Protocol.Message("file_reject", new TransferDecision(descriptor.Id)));
            if (work != null) Finish(work);
        }
    }

    private async Task RunSendAsync(Work work, string path, CancellationToken requested)
    {
        // Yield before callbacks: registration under _gate must complete before any UI event.
        await Task.Yield();
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(work.Stop.Token, requested);
        var token = linked.Token;
        using var closeOnCancel = token.Register(() => { work.Listener?.Stop(); work.Socket?.Dispose(); });
        try
        {
            Publish(work);
            await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
                Protocol.ChunkSize, FileOptions.Asynchronous | FileOptions.SequentialScan);
            if (file.Length > IncomingFilePolicy.MaximumFileBytes) throw new IOException("The maximum file size is 2 GiB.");
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[Protocol.ChunkSize];
            long size = 0;
            int count;
            while ((count = await file.ReadAsync(buffer, token)) != 0)
            {
                size += count;
                if (size > IncomingFilePolicy.MaximumFileBytes) throw new IOException("The maximum file size is 2 GiB.");
                hash.AppendData(buffer, 0, count);
            }
            var checksum = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
            file.Position = 0;
            var listener = NewListener();
            work.Listener = listener;
            token.ThrowIfCancellationRequested();
            listener.Start(8);
            var port = ((IPEndPoint)listener.LocalEndpoint).Port;
            var expires = DateTimeOffset.UtcNow.Add(_options.OfferTimeout);
            var streamToken = Protocol.NewToken();
            new FileExtensionContentTypeProvider().TryGetContentType(path, out var mime);
            var offer = new TransferDescriptor(work.Record.Id, Path.GetFileName(path), size, checksum,
                mime ?? "application/octet-stream", port, streamToken, expires.ToUnixTimeMilliseconds());
            lock (work.Gate) work.Record = work.Record with { FileSize = size, State = TransferState.Waiting };
            Publish(work);
            await work.Peer.SendAsync(Protocol.Message("file_offer", new FileOfferPayload(offer)), token);
            using var admission = CancellationTokenSource.CreateLinkedTokenSource(token);
            admission.CancelAfter(_options.OfferTimeout);
            await work.Accepted.Task.WaitAsync(admission.Token);
            using var socket = await AcceptAuthorizedAsync(listener, streamToken, expires, admission.Token);
            work.Socket = socket;
            token.ThrowIfCancellationRequested();
            listener.Stop();
            Update(work, TransferState.Transferring);
            var output = socket.GetStream();
            long sent = 0;
            while ((count = await file.ReadAsync(buffer, token)) != 0)
            {
                if (count > size - sent) throw new IOException("The source file changed during transfer.");
                using var idle = CancellationTokenSource.CreateLinkedTokenSource(token);
                idle.CancelAfter(_options.IdleTimeout);
                await output.WriteAsync(buffer.AsMemory(0, count), idle.Token);
                sent += count;
                Progress(work, sent);
            }
            if (sent != size) throw new IOException("The source file changed during transfer.");
            socket.Client.Shutdown(SocketShutdown.Send);
            // Bytes written is only local progress. The receiver owns the success decision.
            Update(work, TransferState.AwaitingConfirmation, size);
            try
            {
                await work.Confirmed.Task.WaitAsync(_options.ReceiptTimeout, token);
                Update(work, TransferState.Completed, size);
            }
            catch (TimeoutException)
            {
                Update(work, TransferState.Unconfirmed, size,
                    error: "File sent, but the receiver has not confirmed saving it. Check the other device before retrying.");
            }
            catch (IOException error) { Update(work, TransferState.Unconfirmed, size, error: error.Message); }
        }
        catch (Exception error)
        {
            var cancelled = token.IsCancellationRequested;
            Update(work, cancelled ? work.CancellationState : TransferState.Failed,
                error: work.CancellationReason ?? (error is OperationCanceledException ? "Transfer timed out." : error.Message));
            await BestEffortAsync(work.Peer, Protocol.Message("transfer_cancel", new TransferDecision(work.Record.Id)));
        }
        finally { Finish(work); }
    }

    private async Task RunReceiveAsync(Work work, TransferDescriptor offer)
    {
        await Task.Yield();
        var token = work.Stop.Token;
        using var closeOnCancel = token.Register(() => work.Socket?.Dispose());
        try
        {
            Publish(work);
            await work.Peer.SendAsync(Protocol.Message("file_accept", new TransferDecision(offer.Id)), token);
            using var socket = new TcpClient();
            work.Socket = socket;
            using (var connect = CancellationTokenSource.CreateLinkedTokenSource(token))
            {
                connect.CancelAfter(_options.ConnectTimeout);
                await socket.ConnectAsync(IPAddress.Parse(work.Peer.RemoteHost), offer.StreamPort, connect.Token);
            }
            var stream = socket.GetStream();
            using (var auth = CancellationTokenSource.CreateLinkedTokenSource(token))
            {
                auth.CancelAfter(_options.AuthenticationTimeout);
                if (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() > offer.StreamTokenExpiresAt)
                    throw new IOException("The file token expired before connecting.");
                await stream.WriteAsync(Encoding.ASCII.GetBytes(offer.StreamToken + "\n"), auth.Token);
            }
            Update(work, TransferState.Transferring);
            var saved = await VerifiedFileReceiver.ReceiveAsync(stream, _options.ReceiveDirectory, offer.FileName,
                offer.FileSize, offer.Checksum, _available, completed =>
                {
                    _budget.Progress(offer.Id, offer.FileSize - completed);
                    Progress(work, completed);
                }, _options.IdleTimeout, token);
            Update(work, TransferState.Completed, offer.FileSize, saved);
            // Publication already succeeded. Losing this receipt must not mark the local file as failed.
            await BestEffortAsync(work.Peer, Protocol.Message("transfer_complete", new TransferDecision(offer.Id, offer.FileSize)));
        }
        catch (Exception error)
        {
            Update(work, token.IsCancellationRequested ? work.CancellationState : TransferState.Failed,
                error: work.CancellationReason ?? (error is OperationCanceledException ? "Transfer timed out." : error.Message));
            Notice?.Invoke($"Could not receive {work.Record.FileName}: {work.Record.Error}");
            await BestEffortAsync(work.Peer, Protocol.Message("file_reject", new TransferDecision(offer.Id)));
        }
        finally { _budget.Release(offer.Id); Finish(work); }
    }

    private static TcpListener NewListener()
    {
        if (!Socket.OSSupportsIPv6) return new(IPAddress.Any, 0);
        var listener = new TcpListener(IPAddress.IPv6Any, 0);
        listener.Server.DualMode = true;
        return listener;
    }

    private async Task<TcpClient> AcceptAuthorizedAsync(TcpListener listener, string expected,
        DateTimeOffset expires, CancellationToken token)
    {
        while (true)
        {
            token.ThrowIfCancellationRequested();
            var socket = await listener.AcceptTcpClientAsync(token);
            try
            {
                using var auth = CancellationTokenSource.CreateLinkedTokenSource(token);
                auth.CancelAfter(_options.AuthenticationTimeout);
                var bytes = new byte[44];
                await socket.GetStream().ReadExactlyAsync(bytes, auth.Token);
                var received = Encoding.ASCII.GetString(bytes, 0, 43);
                if (bytes[43] == 10 && DateTimeOffset.UtcNow <= expires && Protocol.TokenMatches(received, expected))
                    return socket;
            }
            catch (Exception error) when (error is IOException or OperationCanceledException or SocketException) { }
            socket.Dispose();
        }
    }

    private static async Task BestEffortAsync(PeerSession peer, ControlEnvelope envelope)
    {
        try { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2)); await peer.SendAsync(envelope, timeout.Token); }
        catch (Exception error) when (error is IOException or OperationCanceledException or System.Net.WebSockets.WebSocketException or ObjectDisposedException) { }
    }

    private void Progress(Work work, long completed)
    {
        var now = Environment.TickCount64;
        if (completed != work.Record.FileSize && now - work.LastProgressTick < 100) return;
        work.LastProgressTick = now;
        Update(work, TransferState.Transferring, completed);
    }

    private void Update(Work work, TransferState state, long? bytes = null, string? path = null, string? error = null)
    {
        lock (work.Gate)
        {
            if (work.Record.IsTerminal) return;
            work.Record = work.Record with { State = state, CompletedBytes = bytes ?? work.Record.CompletedBytes,
                LocalPath = path ?? work.Record.LocalPath, Error = error };
        }
        Publish(work);
    }
    private void Publish(Work work) => Updated?.Invoke(work.Record);

    private void Finish(Work work)
    {
        work.Listener?.Stop();
        work.Socket?.Dispose();
        lock (_gate)
        {
            _active.Remove(work.Record.Id);
            _finished[work.Record.Id] = work.Record;
            if (_finished.Count > 2048) _finished.Remove(_finished.Keys.First());
        }
        lock (work.Gate) { work.Finished = true; work.Stop.Dispose(); }
    }

    public async Task CancelAsync(Guid id)
    {
        Work? work;
        lock (_gate) { _active.TryGetValue(id, out work); work?.Cancel("Cancelled."); }
        if (work != null)
            await BestEffortAsync(work.Peer, Protocol.Message("transfer_cancel", new TransferDecision(id)));
    }

    public void ConnectionClosed(PeerSession peer)
    {
        lock (_gate)
        {
            foreach (var work in _active.Values.Where(w => ReferenceEquals(w.Peer, peer)))
            {
                // A completed data stream may still have been saved even if its control receipt was lost.
                work.Confirmed.TrySetException(new IOException("Connection closed before the receiver confirmed saving."));
                if (work.Record.State != TransferState.AwaitingConfirmation && !work.Record.IsTerminal)
                    work.Cancel("The control connection closed.", TransferState.Failed);
            }
        }
    }

    public async ValueTask DisposeAsync()
    {
        Work[] pending;
        lock (_gate)
        {
            pending = _active.Values.ToArray();
            foreach (var work in pending) work.Cancel("NearLink stopped.");
        }
        await Task.WhenAll(pending.Select(w => w.Task));
    }
}
