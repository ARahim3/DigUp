// The flight recorder: every top-level failure lands here with a time,
// so a bug report can say "send %LocalAppData%\DigUp\error.log".
// Writes never throw (logging must not crash the app it watches).

using System.IO;

namespace DigUp.App;

internal static class ErrorLog
{
    private static readonly object Gate = new();
    private const long MaxBytes = 512 * 1024;

    public static string Path => System.IO.Path.Combine(Settings.Dir, "error.log");

    public static void Write(string message)
    {
        try
        {
            Directory.CreateDirectory(Settings.Dir);
            lock (Gate)
            {
                try
                {
                    if (File.Exists(Path) && new FileInfo(Path).Length > MaxBytes)
                        File.Delete(Path); // cap it: fresh log, not endless growth
                }
                catch { }
                File.AppendAllText(Path, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {message}{Environment.NewLine}");
            }
        }
        catch { }
    }
}
