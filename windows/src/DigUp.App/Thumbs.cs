// Thumbnails: small JPEGs in %LocalAppData%\DigUp\thumbs\, one per file +
// moment, capped at 200 MB (oldest pruned on startup). Images decode with
// GDI+; video frames come from FFmpeg at the result's moment (bundled exe,
// else DIGUP_FFMPEG test override). Anything missing gives null: the UI
// shows an icon instead. Never throws.

using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace DigUp.App;

public static class Thumbs
{
    public const int Size = 320;
    private const long CapBytes = 200L << 20;

    public static string Dir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DigUp", "thumbs");

    public static void Prune()
    {
        try
        {
            var dir = new DirectoryInfo(Dir);
            if (!dir.Exists) return;
            var files = dir.GetFiles("*.jpg").OrderBy(f => f.LastWriteTimeUtc).ToList();
            long total = files.Sum(f => f.Length);
            foreach (var f in files)
            {
                if (total <= CapBytes) break;
                total -= f.Length;
                try { f.Delete(); } catch { }
            }
        }
        catch { }
    }

    /// <summary>Thumbnail for an image file, or null.</summary>
    public static string? ForImage(string path)
    {
        string key = Key(path, "img");
        string dest = Path.Combine(Dir, key);
        if (File.Exists(dest)) { Touch(dest); return dest; }
        try
        {
            using var src = Image.FromFile(path);
            using var thumb = Fit(src, Size);
            Directory.CreateDirectory(Dir);
            thumb.Save(dest, ImageFormat.Jpeg);
            return dest;
        }
        catch { return null; }
    }

    /// <summary>Video frame at seconds, or null (needs ffmpeg).</summary>
    public static string? ForVideo(string path, double seconds)
    {
        string key = Key(path, $"frame{(int)seconds}");
        string dest = Path.Combine(Dir, key);
        if (File.Exists(dest)) { Touch(dest); return dest; }
        string? ffmpeg = FindFFmpeg();
        if (ffmpeg is null) return null;
        try
        {
            Directory.CreateDirectory(Dir);
            string tmp = dest + ".tmp.jpg";
            var psi = new System.Diagnostics.ProcessStartInfo(ffmpeg,
                $"-hide_banner -v error -ss {seconds:0.0} -i \"{path}\" -frames:v 1 -vf scale={Size}:-1 \"{tmp}\"")
            { UseShellExecute = false, CreateNoWindow = true };
            using var p = System.Diagnostics.Process.Start(psi);
            if (p is null) return null;
            if (!p.WaitForExit(30000) || p.ExitCode != 0 || !File.Exists(tmp)) return null;
            if (File.Exists(dest)) File.Delete(dest);
            File.Move(tmp, dest);
            return dest;
        }
        catch { return null; }
    }

    private static Bitmap Fit(Image src, int max)
    {
        double scale = Math.Min(1.0, (double)max / Math.Max(src.Width, src.Height));
        int w = Math.Max(1, (int)Math.Round(src.Width * scale));
        int h = Math.Max(1, (int)Math.Round(src.Height * scale));
        var bmp = new Bitmap(w, h);
        using var g = Graphics.FromImage(bmp);
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.DrawImage(src, 0, 0, w, h);
        return bmp;
    }

    private static string Key(string path, string what)
    {
        byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes(what + "|" + path.ToLowerInvariant()));
        return Convert.ToHexString(hash)[..16] + ".jpg";
    }

    private static void Touch(string dest)
    {
        try { File.SetLastWriteTimeUtc(dest, DateTime.UtcNow); } catch { }
    }

    private static string? FindFFmpeg()
    {
        if (Environment.GetEnvironmentVariable("DIGUP_FFMPEG") is { Length: > 0 } dir)
        {
            string f = Path.Combine(dir, "ffmpeg.exe");
            if (File.Exists(f)) return f;
        }
        string next = Path.Combine(AppContext.BaseDirectory, "ffmpeg.exe");
        return File.Exists(next) ? next : null;
    }
}
