using Makaretu.Dns;
using NearLink.Core;
using System.Net;

namespace NearLink.Tests;

internal static class DiscoveryTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.UtcNow;
    private static SRVRecord Srv(string name, string host, int port = 41820) => new()
    { Name = name + "._nearlink._tcp.local", Target = host, Port = (ushort)port, TTL = TimeSpan.FromSeconds(20) };
    private static TXTRecord Txt(string name, Guid id, int version = 2) => new()
    { Name = name + "._nearlink._tcp.local", Strings = [$"deviceId={id}", "platform=android", $"protocolVersion={version}"], TTL = TimeSpan.FromSeconds(20) };
    private static ARecord Address(string host, string ip) => new()
    { Name = host, Address = IPAddress.Parse(ip), TTL = TimeSpan.FromSeconds(20) };

    public static Task Records()
    {
        var cache = new DiscoveryCache();
        var a = Guid.NewGuid(); var b = Guid.NewGuid();
        Program.Check(cache.Apply([Srv("A", "a.local")], null, Guid.Empty, Now).Count == 0, "Wait for TXT and address");
        cache.Apply([Txt("B", b), Txt("A", a)], null, Guid.Empty, Now);
        var devices = cache.Apply([Address("a.local", "192.168.1.2"), Srv("B", "b.local"), Address("b.local", "192.168.1.3")], null, Guid.Empty, Now);
        Program.Check(devices.Count == 2 && devices.Single(d => d.Id == a).Host == "192.168.1.2", "Match records by owner");
        Program.Check(devices.Single(d => d.Id == b).Host == "192.168.1.3", "Other device remains distinct");
        devices = cache.Apply([Txt("A", a, 1)], null, Guid.Empty, Now);
        Program.Check(devices.Count == 1 && devices[0].Id == b, "Filter protocol v1");
        return Task.CompletedTask;
    }
    public static Task ExpiryAndIPv6()
    {
        var cache = new DiscoveryCache();
        var id = Guid.NewGuid();
        var service = Srv("Phone", "phone.local");
        var address = new AAAARecord { Name = "phone.local", Address = IPAddress.Parse("fe80::1234"), TTL = TimeSpan.FromSeconds(20) };
        var devices = cache.Apply([service, Txt("Phone", id), address], IPAddress.Parse("fe80::1234%7"), Guid.Empty, Now);
        Program.Check(devices.Single().Host == "fe80::1234%7", "Preserve interface scope");
        Program.Check(cache.Apply([], null, Guid.Empty, Now.AddSeconds(21)).Count == 0, "TTL expires");
        cache.Apply([service, Txt("Phone", id), Address("phone.local", "192.168.1.9")], null, Guid.Empty, Now);
        var bye = new PTRRecord { Name = "_nearlink._tcp.local", DomainName = service.Name, TTL = TimeSpan.Zero };
        Program.Check(cache.Apply([bye], null, Guid.Empty, Now).Count == 0, "Goodbye removes service");
        return Task.CompletedTask;
    }
}
