using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace NearLink.Core;

public static class IncomingFilePolicy
{
    public const long MaximumFileBytes = 2L * 1024 * 1024 * 1024;
    public const long MinimumFreeBytes = 512L * 1024 * 1024;
    public const long LowStorageBytes = MaximumFileBytes;
    public const int MaximumConcurrentReceives = 10;

    public static void Validate(long size, string? checksum)
    {
        if (size < 0 || size > MaximumFileBytes) throw new IOException("The maximum file size is 2 GiB.");
        if (checksum is not { Length: 64 } || !checksum.All(char.IsAsciiHexDigit))
            throw new IOException("Invalid SHA-256 checksum.");
    }

    public static string? CheckCapacity(long required, long available, long reserved = 0)
    {
        var usable = Math.Max(0, available - reserved);
        if (required < 0 || usable < MinimumFreeBytes || required > usable - MinimumFreeBytes)
            throw new IOException("Not enough storage. NearLink keeps at least 512 MiB free.");
        var remaining = usable - required;
        return remaining < LowStorageBytes
            ? $"Storage is running low. About {remaining / (1024.0 * 1024 * 1024):F2} GiB will remain after current receives."
            : null;
    }

    public static long AvailableBytes(string directory)
    {
        if (OperatingSystem.IsWindows())
        {
            if (!GetDiskFreeSpaceEx(directory, out var available, out _, out _))
                throw new IOException("Could not check free storage.", new System.ComponentModel.Win32Exception());
            return (long)Math.Min(available, (ulong)long.MaxValue);
        }
        return new DriveInfo(Path.GetPathRoot(Path.GetFullPath(directory))!).AvailableFreeSpace;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetDiskFreeSpaceEx(string directory, out ulong available, out ulong total, out ulong free);

    // Apply Windows rules even in portable tests: remove paths, ADS syntax, reserved names and trailing dots.
    public static string SafeName(string? name)
    {
        var leaf = (name ?? "").Replace('\\', '/').Split('/').Last();
        var cleaned = new string(leaf.Where(c => !char.IsControl(c) && !"<>:\"/\\|?*".Contains(c)).ToArray()).Trim().TrimEnd('.');
        cleaned = string.Concat(cleaned.EnumerateRunes().Take(120).Select(r => r.ToString())).TrimEnd(' ', '.');
        var stem = cleaned.Split('.')[0].TrimEnd(' ', '.').ToUpperInvariant();
        if (stem is "CON" or "PRN" or "AUX" or "NUL" or "CLOCK$" or "CONIN$" or "CONOUT$"
            || (stem.Length == 4 && (stem.StartsWith("COM") || stem.StartsWith("LPT"))
                && (stem[3] is >= '0' and <= '9' or '¹' or '²' or '³')))
            cleaned = "_" + cleaned;
        return string.IsNullOrWhiteSpace(cleaned) || cleaned is "." or ".." ? "NearLink-file" : cleaned;
    }
}

public sealed class ReceiveBudget(Func<long> availableBytes)
{
    private readonly object _gate = new();
    private readonly Dictionary<Guid, long> _remaining = [];
    public int Count { get { lock (_gate) return _remaining.Count; } }
    public string? Reserve(Guid id, long bytes)
    {
        lock (_gate)
        {
            if (_remaining.ContainsKey(id)) throw new IOException("Duplicate transfer.");
            if (_remaining.Count >= IncomingFilePolicy.MaximumConcurrentReceives) throw new IOException("Too many incoming files. Try again later.");
            var warning = IncomingFilePolicy.CheckCapacity(bytes, availableBytes(), _remaining.Values.Sum());
            _remaining.Add(id, bytes);
            return warning;
        }
    }
    public void Progress(Guid id, long remaining) { lock (_gate) if (_remaining.ContainsKey(id)) _remaining[id] = Math.Max(0, remaining); }
    public void Release(Guid id) { lock (_gate) _remaining.Remove(id); }
}

public static class VerifiedFileReceiver
{
    public static async Task<string> ReceiveAsync(Stream input, string directory, string fileName, long size,
        string checksum, Func<long> availableBytes, Action<long> progress, TimeSpan idleTimeout, CancellationToken token)
    {
        IncomingFilePolicy.Validate(size, checksum);
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".nearlink-{Guid.NewGuid():N}.partial");
        try
        {
            using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                Protocol.ChunkSize, FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                var buffer = new byte[Protocol.ChunkSize];
                long completed = 0;
                while (true)
                {
                    using var idle = CancellationTokenSource.CreateLinkedTokenSource(token);
                    idle.CancelAfter(idleTimeout);
                    var count = await input.ReadAsync(buffer, idle.Token);
                    if (count == 0) break;
                    if (count > size - completed) throw new IOException("The sender exceeded the advertised file size.");
                    IncomingFilePolicy.CheckCapacity(count, availableBytes());
                    await output.WriteAsync(buffer.AsMemory(0, count), token);
                    digest.AppendData(buffer, 0, count);
                    completed += count;
                    progress(completed);
                }
                if (completed != size) throw new IOException("The file stream ended early.");
                if (!Convert.ToHexString(digest.GetHashAndReset()).Equals(checksum, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("The received file failed SHA-256 verification.");
                await output.FlushAsync(token);
                output.Flush(flushToDisk: true);
            }
            token.ThrowIfCancellationRequested();
            var safeName = IncomingFilePolicy.SafeName(fileName);
            var destination = Path.Combine(directory, safeName);
            while (true)
            {
                try { File.Move(temporary, destination, overwrite: false); return destination; }
                catch (IOException) when (File.Exists(destination) || Directory.Exists(destination))
                {
                    destination = Path.Combine(directory,
                        $"{Path.GetFileNameWithoutExtension(safeName)}-{Guid.NewGuid():N}{Path.GetExtension(safeName)}");
                }
            }
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
