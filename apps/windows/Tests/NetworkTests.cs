using NearLink.Core;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Threading.Channels;

namespace NearLink.Tests;

internal static class NetworkTests
{
    private static ClientOptions Options(string root, string name) => new(
        Path.Combine(root, name, "state"), Path.Combine(root, name, "received"))
    {
        ControlPort = 0, EnableDiscovery = false, AvailableBytes = () => 8L * 1024 * 1024 * 1024,
        OfferTimeout = TimeSpan.FromSeconds(2), ReceiptTimeout = TimeSpan.FromSeconds(1),
        IdleTimeout = TimeSpan.FromSeconds(2), AuthenticationTimeout = TimeSpan.FromMilliseconds(250)
    };
    private static NearbyDevice Endpoint(NearLinkClient client) => new(client.LocalDevice, "127.0.0.1", client.ControlPort);

    public static async Task Messages()
    {
        using var directory = new TemporaryDirectory();
        await using var a = new NearLinkClient(Options(directory.Path, "a"));
        await using var b = new NearLinkClient(Options(directory.Path, "b"));
        await using var c = new NearLinkClient(Options(directory.Path, "c"));
        await Task.WhenAll(a.StartAsync(), b.StartAsync(), c.StartAsync());
        a.UpdatePeers([Endpoint(b), Endpoint(c)]); b.UpdatePeers([Endpoint(a)]); c.UpdatePeers([Endpoint(a)]);
        await Task.WhenAll(a.SendTextAsync(b.LocalDevice.Id, "你好 👋"), b.SendTextAsync(a.LocalDevice.Id, "Android-style reply"),
            c.SendTextAsync(a.LocalDevice.Id, "third device"));
        var entries = a.Snapshot().Entries;
        Program.Check(entries.Count(e => e.PeerID == b.LocalDevice.Id) == 2, "Peer B conversation");
        Program.Check(entries.Single(e => e.PeerID == c.LocalDevice.Id).Text == "third device", "Peer C conversation isolation");
        Program.Check(b.Snapshot().Entries.Any(e => e.Incoming && e.Text == "你好 👋"), "UTF-8 text");
    }

    public static async Task Fragmentation()
    {
        using var directory = new TemporaryDirectory();
        await using var app = new NearLinkClient(Options(directory.Path, "app"));
        await app.StartAsync();
        using var socket = new ClientWebSocket();
        socket.Options.Proxy = null;
        await socket.ConnectAsync(new Uri($"ws://127.0.0.1:{app.ControlPort}/"), default);
        var profile = new DeviceProfile(Guid.NewGuid(), "Fragmented peer", "android");
        await SendRaw(socket, Protocol.Message("hello", new HelloPayload(profile)));
        var text = Protocol.Message("text_message", new TextPayload("分片🙂正确", profile.Id));
        var bytes = Protocol.Encode(text);
        for (var i = 0; i < bytes.Length; i++)
            await socket.SendAsync(bytes.AsMemory(i, 1), WebSocketMessageType.Text, i == bytes.Length - 1, default);
        await Program.Until(() => app.Snapshot().Entries.Any(e => e.Text == "分片🙂正确"));
        await SendRaw(socket, text);
        var ackCount = 0;
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(4));
        while (ackCount < 2)
        {
            var received = await ReadRaw(socket, deadline.Token);
            if (received.Type == "ack" && Protocol.Payload<AckPayload>(received).MessageID == text.MessageID) ackCount++;
        }
        Program.Check(app.Snapshot().Entries.Count(e => e.Text == "分片🙂正确") == 1, "Duplicate delivery must not duplicate history");
        // ACKing an ACK must not generate a feedback loop.
        await SendRaw(socket, Protocol.Ack(text.MessageID));
        using var shortWait = new CancellationTokenSource(TimeSpan.FromMilliseconds(150));
        await Program.Throws(() => ReadRaw(socket, shortWait.Token));
    }

    public static async Task Files()
    {
        using var directory = new TemporaryDirectory();
        var ao = Options(directory.Path, "a"); var bo = Options(directory.Path, "b");
        await using var a = new NearLinkClient(ao);
        await using var b = new NearLinkClient(bo);
        await Task.WhenAll(a.StartAsync(), b.StartAsync());
        a.UpdatePeers([Endpoint(b)]); b.UpdatePeers([Endpoint(a)]);
        var original = Path.Combine(bo.ReceiveDirectory, "中文-video.mp4");
        await File.WriteAllTextAsync(original, "keep original");
        var path = Path.Combine(directory.Path, "中文-video.mp4");
        var bytes = new byte[Protocol.ChunkSize + 123]; Random.Shared.NextBytes(bytes);
        await File.WriteAllBytesAsync(path, bytes);
        var empty = Path.Combine(directory.Path, "empty.bin"); await File.WriteAllBytesAsync(empty, []);
        await Task.WhenAll(a.SendFileAsync(b.LocalDevice.Id, path), b.SendFileAsync(a.LocalDevice.Id, empty));
        Program.Check(a.Snapshot().Transfers.All(t => t.State == TransferState.Completed), "A completed both directions");
        Program.Check(b.Snapshot().Transfers.All(t => t.State == TransferState.Completed), "B completed both directions");
        var saved = b.Snapshot().Transfers.Single(t => t.Incoming).LocalPath!;
        Program.Check(saved != original && (await File.ReadAllBytesAsync(saved)).SequenceEqual(bytes), "Verified same-name receive");
        Program.Check(await File.ReadAllTextAsync(original) == "keep original", "Original is preserved");
        Program.Check(new FileInfo(a.Snapshot().Transfers.Single(t => t.Incoming).LocalPath!).Length == 0, "Empty file over TCP");
    }

    public static async Task Confirmation()
    {
        using var directory = new TemporaryDirectory();
        await using var peer = new ControlledPeer();
        await peer.StartAsync();
        await using var app = new NearLinkClient(Options(directory.Path, "app") with { ReceiptTimeout = TimeSpan.FromSeconds(3) });
        await app.StartAsync(); app.UpdatePeers([peer.Endpoint]);
        var path = Path.Combine(directory.Path, "sample.txt"); await File.WriteAllTextAsync(path, "confirmed bytes");
        var sending = app.SendFileAsync(peer.Profile.Id, path);
        var (session, offer) = await peer.OfferAsync();
        await session.SendAsync(Protocol.Message("file_accept", new TransferDecision(offer.Id)));
        var data = await ReadOfferedFile(offer);
        Program.Check(Program.Hash(data) == offer.Checksum, "Sent bytes match offer");
        await Program.Until(() => app.Snapshot().Transfers.Single().State == TransferState.AwaitingConfirmation);
        Program.Check(!sending.IsCompleted, "Do not finish at local EOF");
        await session.SendAsync(Protocol.Message("transfer_complete", new TransferDecision(offer.Id, offer.FileSize + 1)));
        await Task.Delay(75);
        Program.Check(!sending.IsCompleted, "Ignore a receipt with a mismatched byte count");
        await session.SendAsync(Protocol.Message("transfer_complete", new TransferDecision(offer.Id, offer.FileSize)));
        await sending;
        Program.Check(app.Snapshot().Transfers.Single().State == TransferState.Completed, "Matching receipt completes sender");
    }

    public static async Task MissingReceipt()
    {
        using var directory = new TemporaryDirectory();
        await using var peer = new ControlledPeer(); await peer.StartAsync();
        await using var app = new NearLinkClient(Options(directory.Path, "app"));
        await app.StartAsync(); app.UpdatePeers([peer.Endpoint]);
        var path = Path.Combine(directory.Path, "sample"); await File.WriteAllTextAsync(path, "unconfirmed bytes");
        var sending = app.SendFileAsync(peer.Profile.Id, path);
        var (session, offer) = await peer.OfferAsync();
        await session.SendAsync(Protocol.Message("file_accept", new TransferDecision(offer.Id)));
        await ReadOfferedFile(offer);
        await sending;
        Program.Check(app.Snapshot().Transfers.Single().State == TransferState.Unconfirmed, "Lost receipt is not success");
        await session.SendAsync(Protocol.Message("transfer_complete", new TransferDecision(offer.Id, offer.FileSize)));
        await Program.Until(() => app.Snapshot().Transfers.Single().State == TransferState.Completed);
    }

    public static async Task UnansweredOffer()
    {
        using var directory = new TemporaryDirectory();
        await using var peer = new ControlledPeer(); await peer.StartAsync();
        await using var app = new NearLinkClient(Options(directory.Path, "app") with { OfferTimeout = TimeSpan.FromMilliseconds(400) });
        await app.StartAsync(); app.UpdatePeers([peer.Endpoint]);
        var path = Path.Combine(directory.Path, "sample"); await File.WriteAllTextAsync(path, "offer timeout");
        var sending = app.SendFileAsync(peer.Profile.Id, path);
        var (_, offer) = await peer.OfferAsync();
        await sending;
        Program.Check(app.Snapshot().Transfers.Single().State == TransferState.Failed, "Unanswered offer times out");
        using var socket = new TcpClient();
        await Program.Throws(async () => await socket.ConnectAsync(IPAddress.Loopback, offer.StreamPort));
    }

    public static async Task InvalidToken()
    {
        using var directory = new TemporaryDirectory();
        await using var peer = new ControlledPeer(); await peer.StartAsync();
        await using var app = new NearLinkClient(Options(directory.Path, "app"));
        await app.StartAsync(); app.UpdatePeers([peer.Endpoint]);
        var path = Path.Combine(directory.Path, "sample"); await File.WriteAllTextAsync(path, "token protected");
        var sending = app.SendFileAsync(peer.Profile.Id, path);
        var (session, offer) = await peer.OfferAsync();
        await session.SendAsync(Protocol.Message("file_accept", new TransferDecision(offer.Id)));
        using (var invalid = new TcpClient())
        {
            await invalid.ConnectAsync(IPAddress.Loopback, offer.StreamPort);
            await invalid.GetStream().WriteAsync(Encoding.ASCII.GetBytes(Protocol.NewToken() + "\n"));
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            Program.Check(await invalid.GetStream().ReadAsync(new byte[1], deadline.Token) == 0, "Wrong token receives no bytes");
        }
        var data = await ReadOfferedFile(offer);
        Program.Check(Program.Hash(data) == offer.Checksum, "Legitimate peer can still receive");
        await session.SendAsync(Protocol.Message("transfer_complete", new TransferDecision(offer.Id, data.Length)));
        await sending;
        Program.Check(app.Snapshot().Transfers.Single().State == TransferState.Completed, "Authorized send completes");
    }

    public static async Task Cancellation()
    {
        using var directory = new TemporaryDirectory();
        await using var peer = new ControlledPeer(); await peer.StartAsync();
        await using var app = new NearLinkClient(Options(directory.Path, "app"));
        await app.StartAsync(); app.UpdatePeers([peer.Endpoint]);
        var path = Path.Combine(directory.Path, "large");
        await using (var file = File.Create(path)) file.SetLength(32 * 1024 * 1024);
        var sending = app.SendFileAsync(peer.Profile.Id, path);
        var (session, offer) = await peer.OfferAsync();
        await session.SendAsync(Protocol.Message("file_accept", new TransferDecision(offer.Id)));
        using var socket = new TcpClient { ReceiveBufferSize = 4096 };
        await socket.ConnectAsync(IPAddress.Loopback, offer.StreamPort);
        await socket.GetStream().WriteAsync(Encoding.ASCII.GetBytes(offer.StreamToken + "\n"));
        await Program.Until(() => app.Snapshot().Transfers.Single().State == TransferState.Transferring);
        await app.CancelTransferAsync(offer.Id);
        await sending.WaitAsync(TimeSpan.FromSeconds(3));
        Program.Check(app.Snapshot().Transfers.Single().State == TransferState.Cancelled, "Cancellation is terminal");
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        var buffer = new byte[Protocol.ChunkSize];
        try { while (await socket.GetStream().ReadAsync(buffer, deadline.Token) > 0) { } }
        catch (IOException) { }
        Program.Check(!deadline.IsCancellationRequested, "Active data connection closes");
    }

    public static async Task OversizedReceive()
    {
        using var directory = new TemporaryDirectory();
        var options = Options(directory.Path, "app");
        await using var app = new NearLinkClient(options); await app.StartAsync();
        using var control = new ClientWebSocket();
        control.Options.Proxy = null;
        await control.ConnectAsync(new Uri($"ws://127.0.0.1:{app.ControlPort}/"), default);
        var profile = new DeviceProfile(Guid.NewGuid(), "Bad sender", "android");
        await SendRaw(control, Protocol.Message("hello", new HelloPayload(profile)));
        var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
        try
        {
            var offer = new TransferDescriptor(Guid.NewGuid(), "bad.mp4", 1, Program.Hash([1]), "video/mp4",
                ((IPEndPoint)listener.LocalEndpoint).Port, Protocol.NewToken(), DateTimeOffset.UtcNow.AddMinutes(1).ToUnixTimeMilliseconds());
            await SendRaw(control, Protocol.Message("file_offer", new FileOfferPayload(offer)));
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(4));
            using var data = await listener.AcceptTcpClientAsync(timeout.Token);
            var auth = new byte[44]; await data.GetStream().ReadExactlyAsync(auth, timeout.Token);
            Program.Check(Encoding.ASCII.GetString(auth) == offer.StreamToken + "\n", "Token first");
            await data.GetStream().WriteAsync(new byte[] { 1, 2 }, timeout.Token);
            data.Client.Shutdown(SocketShutdown.Send);
            await Program.Until(() => app.Snapshot().Transfers.Any(t => t.Id == offer.Id && t.State == TransferState.Failed));
            Program.Check(!Directory.EnumerateFileSystemEntries(options.ReceiveDirectory).Any(), "No invalid file survives");
        }
        finally { listener.Stop(); }
    }

    public static async Task EndpointChange()
    {
        using var directory = new TemporaryDirectory();
        var receiverOptions = Options(directory.Path, "receiver");
        await using var sender = new NearLinkClient(Options(directory.Path, "sender"));
        await sender.StartAsync();
        Guid identity;
        await using (var first = new NearLinkClient(receiverOptions))
        {
            await first.StartAsync(); identity = first.LocalDevice.Id;
            sender.UpdatePeers([Endpoint(first)]);
            await sender.SendTextAsync(identity, "before restart");
        }
        await using var second = new NearLinkClient(receiverOptions); await second.StartAsync();
        sender.UpdatePeers([Endpoint(second)]);
        await sender.SendTextAsync(identity, "after restart");
        Program.Check(second.LocalDevice.Id == identity && second.Snapshot().Entries.Any(e => e.Text == "after restart"), "Reconnect to latest discovered port");
    }

    private static Task SendRaw(ClientWebSocket socket, ControlEnvelope message) =>
        socket.SendAsync(Protocol.Encode(message).AsMemory(), WebSocketMessageType.Text, true, default).AsTask();
    private static async Task<ControlEnvelope> ReadRaw(ClientWebSocket socket, CancellationToken token)
    {
        using var bytes = new MemoryStream(); var buffer = new byte[4096];
        ValueWebSocketReceiveResult result;
        do
        {
            result = await socket.ReceiveAsync(buffer.AsMemory(), token);
            if (result.MessageType == WebSocketMessageType.Close) throw new IOException("Socket closed.");
            bytes.Write(buffer, 0, result.Count);
        } while (!result.EndOfMessage);
        return Protocol.Decode(bytes.ToArray());
    }
    private static async Task<byte[]> ReadOfferedFile(TransferDescriptor offer)
    {
        using var socket = new TcpClient();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(4));
        await socket.ConnectAsync(IPAddress.Loopback, offer.StreamPort, timeout.Token);
        await socket.GetStream().WriteAsync(Encoding.ASCII.GetBytes(offer.StreamToken + "\n"), timeout.Token);
        using var bytes = new MemoryStream();
        await socket.GetStream().CopyToAsync(bytes, timeout.Token);
        return bytes.ToArray();
    }

    private sealed class ControlledPeer : IAsyncDisposable
    {
        private readonly ControlServer _server = new();
        private readonly CancellationTokenSource _stop = new();
        private readonly Channel<(PeerSession, TransferDescriptor)> _offers = Channel.CreateUnbounded<(PeerSession, TransferDescriptor)>();
        public DeviceProfile Profile { get; } = new(Guid.NewGuid(), "Controlled peer", "android");
        public NearbyDevice Endpoint => new(Profile, "127.0.0.1", _server.Port);
        public Task StartAsync() => _server.StartAsync(0, async (socket, host, cancellation) =>
        {
            using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token, cancellation);
            await using var session = new PeerSession(socket, host, null, lifetime.Token);
            session.MessageReceived = (connection, envelope) =>
            {
                if (envelope.Type == "hello") connection.Identify(Protocol.Payload<HelloPayload>(envelope).Device.Id);
                if (envelope.Type == "file_offer") _offers.Writer.TryWrite((connection, Protocol.Payload<FileOfferPayload>(envelope).Transfer));
                return Task.CompletedTask;
            };
            var receiving = session.RunAsync();
            await session.SendAsync(Protocol.Message("hello", new HelloPayload(Profile)));
            await receiving;
        });
        public async Task<(PeerSession, TransferDescriptor)> OfferAsync() =>
            await _offers.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(8));
        public async ValueTask DisposeAsync() { _stop.Cancel(); await _server.DisposeAsync(); }
    }
}
