using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace NearLink.Core;

public static class Protocol
{
    public const int Version = 2;
    public const string ServiceType = "_nearlink._tcp";
    public const int Port = 41820;
    public const int ChunkSize = 256 * 1024;
    public const int MaximumControlBytes = 1024 * 1024;
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
        MaxDepth = 32
    };

    // messageID belongs to this frame. An ACK's payload.messageID refers to the original frame.
    public static ControlEnvelope Message<T>(string type, T payload) =>
        new(Version, type, Guid.NewGuid(), DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            JsonSerializer.SerializeToElement(payload, Json));
    public static ControlEnvelope Ack(Guid id) => Message("ack", new AckPayload(id));
    public static byte[] Encode(ControlEnvelope envelope) => JsonSerializer.SerializeToUtf8Bytes(envelope, Json);

    public static ControlEnvelope Decode(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length > MaximumControlBytes) throw new InvalidDataException("Control message is too large.");
        var envelope = JsonSerializer.Deserialize<ControlEnvelope>(bytes, Json)
            ?? throw new InvalidDataException("Empty control message.");
        if (envelope.Version != Version || envelope.MessageID == Guid.Empty || envelope.Timestamp <= 0
            || envelope.Timestamp > DateTimeOffset.MaxValue.ToUnixTimeMilliseconds()
            || string.IsNullOrWhiteSpace(envelope.Type) || envelope.Payload.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("Invalid or incompatible NearLink control message.");
        return envelope;
    }

    public static T Payload<T>(ControlEnvelope envelope) =>
        envelope.Payload.Deserialize<T>(Json) ?? throw new InvalidDataException("Missing message payload.");

    public static string NewToken() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
        .TrimEnd('=').Replace('+', '-').Replace('/', '_');
    public static bool ValidToken(string? value) => value is { Length: 43 }
        && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_');
    public static bool TokenMatches(string value, string expected) => ValidToken(value) && ValidToken(expected)
        && CryptographicOperations.FixedTimeEquals(
            System.Text.Encoding.ASCII.GetBytes(value), System.Text.Encoding.ASCII.GetBytes(expected));
}

public sealed record ControlEnvelope(int Version, string Type,
    [property: JsonPropertyName("messageID")] Guid MessageID,
    [property: JsonConverter(typeof(UnixMillisecondsConverter))] long Timestamp, JsonElement Payload);
public sealed record DeviceProfile(Guid Id, string Name, string Platform, int ProtocolVersion = Protocol.Version);
public sealed record NearbyDevice(DeviceProfile Profile, string Host, int Port, string[]? AlternativeHosts = null)
{
    public Guid Id => Profile.Id;
}
public sealed record HelloPayload(DeviceProfile Device);
public sealed record TextPayload(string Text, [property: JsonPropertyName("senderID")] Guid? SenderID = null);
public sealed record AckPayload([property: JsonPropertyName("messageID")] Guid MessageID);
public sealed record FileOfferPayload(TransferDescriptor Transfer);
public sealed record TransferDecision([property: JsonPropertyName("transferID")] Guid TransferID, long ReceivedBytes = 0);
public sealed record TransferProgress([property: JsonPropertyName("transferID")] Guid TransferID, long CompletedBytes);
public sealed record TransferDescriptor(Guid Id, string FileName, long FileSize, string Checksum,
    string? MimeType, int StreamPort, string StreamToken,
    [property: JsonConverter(typeof(UnixMillisecondsConverter))] long StreamTokenExpiresAt);

// Swift's millisecondsSince1970 encoder may emit fractional milliseconds; Android emits integers.
// Only date fields permit fractions. File sizes and byte counts remain strict 64-bit integers.
public sealed class UnixMillisecondsConverter : JsonConverter<long>
{
    public override long Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.Number) throw new JsonException("Expected a numeric Unix millisecond timestamp.");
        if (reader.TryGetInt64(out var value)) return value;
        if (reader.TryGetDouble(out var fractional) && double.IsFinite(fractional) && fractional >= 0
            && fractional <= DateTimeOffset.MaxValue.ToUnixTimeMilliseconds())
            return (long)fractional;
        throw new JsonException("Invalid Unix millisecond timestamp.");
    }
    public override void Write(Utf8JsonWriter writer, long value, JsonSerializerOptions options) => writer.WriteNumberValue(value);
}

public sealed record ClientOptions(string StateDirectory, string ReceiveDirectory)
{
    public int ControlPort { get; init; } = Protocol.Port;
    public bool EnableDiscovery { get; init; } = true;
    public TimeSpan ConnectTimeout { get; init; } = TimeSpan.FromSeconds(10);
    public TimeSpan MessageAckTimeout { get; init; } = TimeSpan.FromSeconds(6);
    public TimeSpan OfferTimeout { get; init; } = TimeSpan.FromMinutes(2);
    public TimeSpan AuthenticationTimeout { get; init; } = TimeSpan.FromSeconds(5);
    public TimeSpan IdleTimeout { get; init; } = TimeSpan.FromSeconds(30);
    // Current iOS sends its receipt after optional Photos saving, so allow additional time.
    public TimeSpan ReceiptTimeout { get; init; } = TimeSpan.FromSeconds(60);
    public Func<long>? AvailableBytes { get; init; }
}
