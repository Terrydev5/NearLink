using System.Runtime.InteropServices;

namespace NearLink.Windows;

internal static class WindowsFolders
{
    // Respect redirected Downloads folders instead of guessing UserProfile + "Downloads".
    public static string Downloads()
    {
        var id = new Guid("374DE290-123F-4565-9164-39C4925E467B");
        var result = SHGetKnownFolderPath(ref id, 0, IntPtr.Zero, out var pointer);
        Marshal.ThrowExceptionForHR(result);
        try { return Marshal.PtrToStringUni(pointer) ?? throw new IOException("Downloads is unavailable."); }
        finally { Marshal.FreeCoTaskMem(pointer); }
    }

    [DllImport("shell32.dll")]
    private static extern int SHGetKnownFolderPath(ref Guid id, uint flags, IntPtr token, out IntPtr path);
}
