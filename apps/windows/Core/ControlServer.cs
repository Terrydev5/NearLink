using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using System.Net.WebSockets;

namespace NearLink.Core;

public sealed class ControlServer : IAsyncDisposable
{
    private WebApplication? _app;
    public int Port { get; private set; }

    public async Task StartAsync(int port, Func<WebSocket, string, CancellationToken, Task> accepted,
        CancellationToken token = default)
    {
        // Kestrel binds a normal socket and does not require HttpListener URL ACL registration.
        var builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.UseKestrel(options => options.ListenAnyIP(port));
        var app = builder.Build();
        app.UseWebSockets();
        app.Map("/", async (HttpContext context) =>
        {
            if (!context.WebSockets.IsWebSocketRequest) { context.Response.StatusCode = 400; return; }
            using var socket = await context.WebSockets.AcceptWebSocketAsync();
            var address = context.Connection.RemoteIpAddress;
            if (address?.IsIPv4MappedToIPv6 == true) address = address.MapToIPv4();
            // Numeric address only: a reverse DNS lookup must never delay a control frame.
            await accepted(socket, address?.ToString() ?? "", context.RequestAborted);
        });
        try
        {
            await app.StartAsync(token);
            var addresses = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!;
            Port = new Uri(addresses.Addresses.First()).Port;
            _app = app;
        }
        catch { await app.DisposeAsync(); throw; }
    }

    public async ValueTask DisposeAsync()
    {
        if (_app == null) return;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try { await _app.StopAsync(timeout.Token); }
        finally { await _app.DisposeAsync(); _app = null; }
    }
}
