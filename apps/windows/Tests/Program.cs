using NearLink.Core;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace NearLink.Tests;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        var tests = new (string Name, Func<Task> Run)[]
        {
            ("protocol envelope and ACK contracts", PolicyTests.ProtocolContract),
            ("2 GiB boundaries and concurrent storage reservations", PolicyTests.Limits),
            ("Windows filenames and atomic same-name publication", PolicyTests.Publication),
            ("excess bytes, truncation and checksum cleanup", PolicyTests.FailedStreams),
            ("disk exhaustion, cancellation and idle timeout cleanup", PolicyTests.Interruptions),
            ("stable identity and exact persisted file locations", PolicyTests.History),
            ("DNS split packets, owner matching and protocol filter", DiscoveryTests.Records),
            ("DNS TTL, goodbye and scoped IPv6", DiscoveryTests.ExpiryAndIPv6),
            ("two-way text and simultaneous multi-peer conversations", NetworkTests.Messages),
            ("WebSocket UTF-8 fragmentation and duplicate suppression", NetworkTests.Fragmentation),
            ("bidirectional TCP file transfer and same-name preservation", NetworkTests.Files),
            ("sender waits for matching receiver confirmation", NetworkTests.Confirmation),
            ("lost completion receipt stays unconfirmed", NetworkTests.MissingReceipt),
            ("unanswered offers release their listeners", NetworkTests.UnansweredOffer),
            ("wrong tokens do not consume the legitimate file stream", NetworkTests.InvalidToken),
            ("cancel closes an established data stream", NetworkTests.Cancellation),
            ("receiver rejects excess bytes and cleans its destination", NetworkTests.OversizedReceive),
            ("rediscovery replaces stale connection endpoints", NetworkTests.EndpointChange)
        };
        var failed = 0;
        foreach (var test in tests)
        {
            try { await test.Run().WaitAsync(TimeSpan.FromSeconds(25)); Console.WriteLine($"PASS {test.Name}"); }
            catch (Exception error) { failed++; Console.Error.WriteLine($"FAIL {test.Name}: {error}"); }
        }
        for (var i = 0; i < args.Length; i++)
        {
            if (args[i] == "--ack-fixture" && i + 1 < args.Length)
            {
                var ack = Protocol.Decode(await File.ReadAllBytesAsync(args[++i]));
                Check(ack.Type == "ack" && Protocol.Payload<AckPayload>(ack).MessageID != Guid.Empty, "External ACK fixture");
                Console.WriteLine("PASS external production ACK fixture");
            }
            else if (args[i] == "--export-fixtures" && i + 1 < args.Length)
                await File.WriteAllTextAsync(args[++i], JsonSerializer.Serialize(Fixtures(), Protocol.Json));
            else if (args[i] == "--control-fixtures" && i + 1 < args.Length)
            {
                using var json = JsonDocument.Parse(await File.ReadAllBytesAsync(args[++i]));
                foreach (var property in json.RootElement.EnumerateObject())
                {
                    var envelope = Protocol.Decode(Encoding.UTF8.GetBytes(property.Value.GetRawText()));
                    if (envelope.Type == "file_offer")
                    {
                        var offer = Protocol.Payload<FileOfferPayload>(envelope).Transfer;
                        IncomingFilePolicy.Validate(offer.FileSize, offer.Checksum);
                        Check(Protocol.ValidToken(offer.StreamToken) && offer.StreamTokenExpiresAt > 0, "External file offer");
                    }
                }
                Console.WriteLine("PASS external production control fixtures");
            }
        }
        Console.WriteLine($"{tests.Length - failed}/{tests.Length} Windows core test groups passed.");
        return failed == 0 ? 0 : 1;
    }

    internal static Dictionary<string, ControlEnvelope> Fixtures()
    {
        var id = Guid.NewGuid();
        return new()
        {
            ["hello"] = Protocol.Message("hello", new HelloPayload(new(id, "Windows contract fixture", "windows"))),
            ["text"] = Protocol.Message("text_message", new TextPayload("你好 Windows 👋", id)),
            ["ack"] = Protocol.Ack(id),
            ["offer"] = Protocol.Message("file_offer", new FileOfferPayload(new(id, "图片.png",
                IncomingFilePolicy.MaximumFileBytes, Hash([]), "image/png", 41821, Protocol.NewToken(),
                DateTimeOffset.UtcNow.AddMinutes(2).ToUnixTimeMilliseconds()))),
            ["accept"] = Protocol.Message("file_accept", new TransferDecision(id)),
            ["reject"] = Protocol.Message("file_reject", new TransferDecision(id)),
            ["complete"] = Protocol.Message("transfer_complete", new TransferDecision(id, IncomingFilePolicy.MaximumFileBytes)),
            ["cancel"] = Protocol.Message("transfer_cancel", new TransferDecision(id)),
            ["progress"] = Protocol.Message("transfer_progress", new TransferProgress(id, IncomingFilePolicy.MaximumFileBytes)),
            ["heartbeat"] = Protocol.Message("heartbeat", new { }),
            ["heartbeatAck"] = Protocol.Message("heartbeat_ack", new { })
        };
    }
    internal static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    internal static async Task Throws(Func<Task> body)
    {
        try { await body(); } catch { return; }
        throw new Exception("Expected an exception.");
    }
    internal static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    internal static async Task Until(Func<bool> condition)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        while (!condition()) await Task.Delay(15, timeout.Token);
    }
}

internal sealed class TemporaryDirectory : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"nearlink-tests-{Guid.NewGuid():N}");
    public TemporaryDirectory() => Directory.CreateDirectory(Path);
    public void Dispose() => Directory.Delete(Path, recursive: true);
}

internal static class PolicyTests
{
    private const long Ample = 8L * 1024 * 1024 * 1024;
    private static readonly byte[] Sample = Encoding.UTF8.GetBytes("NearLink 文件 👋");
    public static Task ProtocolContract()
    {
        foreach (var fixture in Program.Fixtures().Values)
            Program.Check(Protocol.Decode(Protocol.Encode(fixture)).Type == fixture.Type, "Envelope round trip");
        var id = Guid.NewGuid();
        var ack = Protocol.Ack(id);
        Program.Check(ack.MessageID != id && Protocol.Payload<AckPayload>(ack).MessageID == id, "ACK correlation");
        Program.Check(ack.Timestamp > 1_000_000_000_000L, "Millisecond timestamp");
        var fractional = JsonSerializer.Serialize(ack, Protocol.Json).Replace(ack.Timestamp.ToString(), ack.Timestamp + ".875");
        Program.Check(Protocol.Decode(Encoding.UTF8.GetBytes(fractional)).Timestamp == ack.Timestamp, "Swift fractional milliseconds");
        return Program.Throws(() => Task.FromResult(Protocol.Decode(Encoding.UTF8.GetBytes(
            JsonSerializer.Serialize(ack, Protocol.Json).Replace(ack.Timestamp.ToString(), "\"2026-01-01T00:00:00Z\"")))));
    }
    public static async Task Limits()
    {
        IncomingFilePolicy.Validate(IncomingFilePolicy.MaximumFileBytes, Program.Hash(Sample));
        IncomingFilePolicy.Validate(0, Program.Hash([]));
        foreach (var size in new[] { -1L, IncomingFilePolicy.MaximumFileBytes + 1 })
            await Program.Throws(() => { IncomingFilePolicy.Validate(size, Program.Hash(Sample)); return Task.CompletedTask; });
        var budget = new ReceiveBudget(() => IncomingFilePolicy.MaximumFileBytes + IncomingFilePolicy.MinimumFreeBytes);
        var id = Guid.NewGuid();
        budget.Reserve(id, IncomingFilePolicy.MaximumFileBytes);
        await Program.Throws(() => Task.FromResult(budget.Reserve(Guid.NewGuid(), 1)));
        budget.Progress(id, 0);
        budget.Reserve(Guid.NewGuid(), 1);
        budget.Release(id);
        Program.Check(budget.Count == 1, "Reservation released");
        var concurrent = new ReceiveBudget(() => Ample);
        for (var i = 0; i < 10; i++) concurrent.Reserve(Guid.NewGuid(), 0);
        await Program.Throws(() => Task.FromResult(concurrent.Reserve(Guid.NewGuid(), 0)));
        Program.Check(IncomingFilePolicy.CheckCapacity(1, IncomingFilePolicy.LowStorageBytes) != null, "Low storage warning");
    }
    public static async Task Publication()
    {
        using var directory = new TemporaryDirectory();
        foreach (var input in new[] { "../file", "C:\\test\\CON.txt", "NUL", "LPT1.mp4", "hello:stream", "...", "你好.png" })
        {
            var name = IncomingFilePolicy.SafeName(input);
            Program.Check(!string.IsNullOrWhiteSpace(name) && !name.Contains(':') && !name.Contains('/') && !name.Contains('\\'), "Safe Windows filename");
        }
        var original = System.IO.Path.Combine(directory.Path, "image.png");
        await File.WriteAllTextAsync(original, "original");
        var paths = await Task.WhenAll(Enumerable.Range(0, 3).Select(_ => VerifiedFileReceiver.ReceiveAsync(
            new MemoryStream(Sample), directory.Path, "image.png", Sample.Length, Program.Hash(Sample).ToUpperInvariant(),
            () => Ample, _ => { }, TimeSpan.FromSeconds(1), default)));
        Program.Check(paths.Distinct().Count() == 3 && await File.ReadAllTextAsync(original) == "original", "Never overwrite same-name files");
        foreach (var path in paths) Program.Check((await File.ReadAllBytesAsync(path)).SequenceEqual(Sample), "Published bytes");
        var empty = await VerifiedFileReceiver.ReceiveAsync(new MemoryStream(), directory.Path, "empty", 0,
            Program.Hash([]), () => Ample, _ => { }, TimeSpan.FromSeconds(1), default);
        Program.Check(new FileInfo(empty).Length == 0, "Empty file");
    }
    public static async Task FailedStreams()
    {
        foreach (var mode in new[] { "excess", "truncated", "checksum" })
        {
            using var directory = new TemporaryDirectory();
            var bytes = mode == "excess" ? Sample.Concat(new byte[] { 1 }).ToArray() : mode == "truncated" ? Sample[..2] : Sample;
            await Program.Throws(() => VerifiedFileReceiver.ReceiveAsync(new MemoryStream(bytes), directory.Path, "bad",
                Sample.Length, mode == "checksum" ? Program.Hash([]) : Program.Hash(Sample), () => Ample, _ => { },
                TimeSpan.FromSeconds(1), default));
            Program.Check(!Directory.EnumerateFileSystemEntries(directory.Path).Any(), "Failure must leave no partial or published file");
        }
    }
    public static async Task Interruptions()
    {
        foreach (var mode in new[] { "full", "shrinks", "cancel", "idle" })
        {
            using var directory = new TemporaryDirectory();
            using var stop = new CancellationTokenSource();
            if (mode == "cancel") stop.Cancel();
            var checks = 0;
            Stream input = mode == "idle" ? new StalledStream() : new FragmentedStream(Sample);
            await Program.Throws(() => VerifiedFileReceiver.ReceiveAsync(input, directory.Path, "bad", Sample.Length,
                Program.Hash(Sample), () => mode == "full" || (mode == "shrinks" && ++checks > 1)
                    ? IncomingFilePolicy.MinimumFreeBytes : Ample,
                _ => { }, TimeSpan.FromMilliseconds(100), stop.Token));
            Program.Check(!Directory.EnumerateFileSystemEntries(directory.Path).Any(), "Interrupted file cleanup");
        }
    }
    public static Task History()
    {
        using var directory = new TemporaryDirectory();
        var store = new HistoryStore(directory.Path);
        var local = store.LoadIdentity();
        Program.Check(local.Id == new HistoryStore(directory.Path).LoadIdentity().Id, "Persistent identity");
        var exact = System.IO.Path.Combine(directory.Path, "same-name-renamed-123.pdf");
        var transfer = new TransferRecord(Guid.NewGuid(), Guid.NewGuid(), "same-name.pdf", 10, true, TransferState.Completed, 10, exact);
        store.Save(new([local], [], [transfer, transfer with { Id = Guid.NewGuid(), State = TransferState.Transferring }]));
        var restored = store.Load();
        Program.Check(restored.Transfers[0].LocalPath == exact, "Persist the actual path, not the advertised name");
        Program.Check(restored.Transfers[1].State == TransferState.Failed, "No fake resume after restart");
        return Task.CompletedTask;
    }
    private sealed class FragmentedStream(byte[] bytes) : MemoryStream(bytes)
    {
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default) =>
            base.ReadAsync(buffer[..Math.Min(buffer.Length, 2)], token);
    }
    private sealed class StalledStream : MemoryStream
    {
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default)
        { await Task.Delay(Timeout.Infinite, token); return 0; }
    }
}
