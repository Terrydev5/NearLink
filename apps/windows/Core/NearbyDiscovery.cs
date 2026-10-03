using Makaretu.Dns;
using System.Net;
using System.Net.Sockets;
using System.Net.NetworkInformation;

namespace NearLink.Core;

// Cache by DNS owner name, not by packet: SRV, TXT and A/AAAA can arrive separately or in AdditionalRecords.
public sealed class DiscoveryCache
{
    private sealed record Cached(ResourceRecord Record, DateTimeOffset Expires, IPAddress? Source);
    private readonly Dictionary<string, Cached> _records = new(StringComparer.OrdinalIgnoreCase);
    private const string Suffix = "._nearlink._tcp.local";

    public IReadOnlyList<NearbyDevice> Apply(IEnumerable<ResourceRecord> records, IPAddress? source,
        Guid localID, DateTimeOffset now)
    {
        foreach (var key in _records.Where(x => x.Value.Expires <= now).Select(x => x.Key).ToArray()) _records.Remove(key);
        foreach (var record in records)
        {
            if (record is not (SRVRecord or TXTRecord or AddressRecord or PTRRecord)) continue;
            var name = Normalize(record.Name);
            if (record is PTRRecord ptr && record.TTL == TimeSpan.Zero)
            {
                var instance = Normalize(ptr.DomainName);
                foreach (var key in _records.Where(x => Normalize(x.Value.Record.Name) == instance).Select(x => x.Key).ToArray())
                    _records.Remove(key);
            }
            var recordKey = $"{name}|{record.Type}|{(record is AddressRecord address ? address.Address.ToString() : "")}";
            if (record.TTL <= TimeSpan.Zero) { _records.Remove(recordKey); continue; }
            if (_records.Count >= 2048 && !_records.ContainsKey(recordKey)) continue;
            var ttl = record.TTL > TimeSpan.FromSeconds(120) ? TimeSpan.FromSeconds(120) : record.TTL;
            _records[recordKey] = new(record, now.Add(ttl), source);
        }
        var result = new Dictionary<Guid, NearbyDevice>();
        foreach (var cached in _records.Values.Where(x => x.Record is SRVRecord).ToArray())
        {
            var service = (SRVRecord)cached.Record;
            var name = Normalize(service.Name);
            if (!name.EndsWith(Suffix, StringComparison.OrdinalIgnoreCase) || service.Port == 0) continue;
            var txt = _records.Values.Select(x => x.Record).OfType<TXTRecord>()
                .FirstOrDefault(x => Normalize(x.Name) == name);
            if (txt == null) continue;
            var properties = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var value in txt.Strings)
            {
                var parts = value.Split('=', 2);
                if (parts.Length == 2) properties[parts[0]] = parts[1];
            }
            if (!properties.TryGetValue("deviceId", out var rawID) || !Guid.TryParse(rawID, out var id)
                || id == Guid.Empty || id == localID || properties.GetValueOrDefault("protocolVersion") != Protocol.Version.ToString())
                continue;
            var hosts = _records.Values.Where(x => x.Record is AddressRecord && Normalize(x.Record.Name) == Normalize(service.Target))
                .Select(AddressWithScope).Where(x => x != null).Cast<IPAddress>()
                .Where(x => !IPAddress.IsLoopback(x) && !x.Equals(IPAddress.Any) && !x.Equals(IPAddress.IPv6Any))
                .OrderBy(x => x.AddressFamily == AddressFamily.InterNetwork ? 0 : 1)
                .Select(x => x.ToString()).Distinct().ToArray();
            if (hosts.Length == 0) continue;
            var displayName = service.Name.ToString().TrimEnd('.')[..^Suffix.Length];
            result[id] = new(new(id, displayName, properties.GetValueOrDefault("platform", "unknown")),
                hosts[0], service.Port, hosts.Skip(1).ToArray());
        }
        return result.Values.OrderBy(x => x.Profile.Name, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    private static IPAddress? AddressWithScope(Cached cached)
    {
        var address = ((AddressRecord)cached.Record).Address;
        if (!address.IsIPv6LinkLocal || address.ScopeId != 0) return address;
        return cached.Source is { AddressFamily: AddressFamily.InterNetworkV6, ScopeId: > 0 } source
            ? new IPAddress(address.GetAddressBytes(), source.ScopeId) : null;
    }
    private static string Normalize(DomainName name) => name.ToString().TrimEnd('.').ToLowerInvariant();
}

public sealed class NearbyDiscovery : IAsyncDisposable
{
    private readonly MulticastService _multicast = new();
    private readonly ServiceDiscovery _services;
    private readonly DiscoveryCache _cache = new();
    private readonly object _gate = new();
    private readonly DeviceProfile _local;
    private readonly int _port;
    private readonly CancellationTokenSource _stop = new();
    private readonly Dictionary<string, DateTimeOffset> _queries = [];
    private ServiceProfile? _profile;
    private Task? _refresh;
    private string _addressSignature = "";
    public event Action<IReadOnlyList<NearbyDevice>>? DevicesChanged;
    public event Action<string>? Error;

    public NearbyDiscovery(DeviceProfile local, int port)
    {
        _local = local;
        _port = port;
        _services = new(_multicast);
        _services.ServiceInstanceDiscovered += (_, e) =>
        {
            Query(e.ServiceInstanceName, DnsType.SRV);
            Query(e.ServiceInstanceName, DnsType.TXT);
        };
        _multicast.AnswerReceived += OnAnswer;
        _multicast.NetworkInterfaceDiscovered += (_, _) => Refresh();
    }

    public void Start()
    {
        _profile = BuildProfile();
        _addressSignature = AddressSignature();
        _multicast.Start();
        _services.Advertise(_profile);
        _services.Announce(_profile);
        Refresh();
        _refresh = RefreshLoopAsync();
    }

    private ServiceProfile BuildProfile()
    {
        // Include a stable suffix to avoid service-name collisions between identically named PCs.
        var profile = new ServiceProfile($"{_local.Name}-{_local.Id.ToString("N")[..6]}", Protocol.ServiceType, (ushort)_port);
        profile.AddProperty("deviceId", _local.Id.ToString());
        profile.AddProperty("platform", "windows");
        profile.AddProperty("protocolVersion", Protocol.Version.ToString());
        return profile;
    }

    private static string AddressSignature() => string.Join("|", NetworkInterface.GetAllNetworkInterfaces()
        .Where(n => n.OperationalStatus == OperationalStatus.Up)
        .SelectMany(n => n.GetIPProperties().UnicastAddresses).Select(a => a.Address.ToString()).Order());

    private void OnAnswer(object? sender, MessageEventArgs args)
    {
        if (_stop.IsCancellationRequested) return;
        try
        {
            var records = args.Message.Answers.Concat(args.Message.AdditionalRecords).ToArray();
            IReadOnlyList<NearbyDevice> devices;
            lock (_gate) devices = _cache.Apply(records, args.RemoteEndPoint.Address, _local.Id, DateTimeOffset.UtcNow);
            DevicesChanged?.Invoke(devices);
            foreach (var service in records.OfType<SRVRecord>().Where(s =>
                s.Name.ToString().Contains("._nearlink._tcp.", StringComparison.OrdinalIgnoreCase)))
            {
                Query(service.Name, DnsType.TXT);
                Query(service.Target, DnsType.A);
                Query(service.Target, DnsType.AAAA);
            }
        }
        catch (Exception error) { Error?.Invoke($"Discovery response ignored: {error.Message}"); }
    }

    private void Query(DomainName name, DnsType type)
    {
        if (_stop.IsCancellationRequested) return;
        var key = $"{name}|{type}";
        lock (_gate)
        {
            var now = DateTimeOffset.UtcNow;
            if (_queries.TryGetValue(key, out var last) && now - last < TimeSpan.FromSeconds(5)) return;
            if (_queries.Count > 2048) _queries.Clear();
            _queries[key] = now;
        }
        try { _multicast.SendQuery(name, type: type); }
        catch (Exception error) { Error?.Invoke($"Discovery query failed: {error.Message}"); }
    }

    public void Refresh()
    {
        if (_stop.IsCancellationRequested) return;
        try { _services.QueryServiceInstances(Protocol.ServiceType); }
        catch (Exception error) { Error?.Invoke($"Discovery unavailable: {error.Message}"); }
    }

    private async Task RefreshLoopAsync()
    {
        try
        {
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(10));
            while (await timer.WaitForNextTickAsync(_stop.Token))
            {
                try
                {
                    var current = AddressSignature();
                    if (current != _addressSignature)
                    {
                        if (_profile != null) _services.Unadvertise(_profile);
                        _profile = BuildProfile();
                        _services.Advertise(_profile);
                        _services.Announce(_profile);
                        _addressSignature = current;
                    }
                }
                catch (Exception error) { Error?.Invoke($"Could not refresh the local network advertisement: {error.Message}"); }
                Refresh();
                IReadOnlyList<NearbyDevice> devices;
                lock (_gate) devices = _cache.Apply([], null, _local.Id, DateTimeOffset.UtcNow);
                DevicesChanged?.Invoke(devices);
            }
        }
        catch (OperationCanceledException) { }
    }

    public async ValueTask DisposeAsync()
    {
        _stop.Cancel();
        if (_refresh != null) await _refresh;
        try { if (_profile != null) _services.Unadvertise(_profile); }
        finally { _services.Dispose(); _multicast.Dispose(); }
    }
}
