// Real image decoder on Windows GDI+ (JPEG, PNG, BMP, GIF, TIFF).
// Throws ExtractError.TooSmall when the long side is under minSide (the file
// counts as skipped, not failed) and ExtractError.Unreadable for anything
// else (HEIC/RAW/WebP need a codec Windows may not have: the message says so).

using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace DigUp.Core;

public sealed class GdiImageDecoder : IImageDecoder
{
    public PreparedImage Decode(string sourcePath, int maxPixel, int minSide, string outputFolder, bool png)
    {
        Image src;
        try { src = Image.FromFile(sourcePath); }
        catch (OutOfMemoryException) { throw ExtractError.Unreadable("not a picture Windows can read (needs a codec?)"); }
        catch (Exception ex) { throw ExtractError.Unreadable("can't read it: " + FirstLine(ex.Message)); }
        using (src)
        {
            int w = src.Width, h = src.Height;
            if (Math.Max(w, h) < minSide) throw ExtractError.TooSmall(w, h);
            string? taken = Taken(src);
            double scale = Math.Min(1.0, (double)maxPixel / Math.Max(w, h));
            int tw = Math.Max(1, (int)Math.Round(w * scale));
            int th = Math.Max(1, (int)Math.Round(h * scale));
            Directory.CreateDirectory(outputFolder);
            string dest = Path.Combine(outputFolder,
                Guid.NewGuid().ToString("N") + (png ? ".png" : ".jpg"));
            if (scale >= 1.0 && (png || IsJpeg(sourcePath)))
            {
                // Already small enough: copy bytes, no quality lost.
                File.Copy(sourcePath, dest);
                return new PreparedImage(dest, w, h, taken);
            }
            using var thumb = new Bitmap(tw, th);
            using (var g = Graphics.FromImage(thumb))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.CompositingQuality = CompositingQuality.HighQuality;
                g.DrawImage(src, 0, 0, tw, th);
            }
            if (png) thumb.Save(dest, ImageFormat.Png);
            else
            {
                var codec = Codec("image/jpeg") ?? throw ExtractError.Unreadable("no JPEG writer on this PC");
                using var p = new EncoderParameters(1);
                using var qp = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 90L);
                p.Param[0] = qp;
                thumb.Save(dest, codec, p);
            }
            return new PreparedImage(dest, w, h, taken);
        }
    }

    // EXIF DateTimeOriginal (tag 0x9003), as the camera wrote it, if present.
    private static string? Taken(Image src)
    {
        try
        {
            const int DateTimeOriginal = 0x9003;
            if (!src.PropertyIdList.Contains(DateTimeOriginal)) return null;
            var item = src.GetPropertyItem(DateTimeOriginal);
            byte[] raw = item.Value ?? [];
            return System.Text.Encoding.ASCII.GetString(raw).Trim('\0', ' ', '\r', '\n');
        }
        catch { return null; }
    }

    private static ImageCodecInfo? Codec(string mime)
    {
        foreach (var c in ImageCodecInfo.GetImageEncoders())
            if (c.MimeType.Equals(mime, StringComparison.OrdinalIgnoreCase)) return c;
        return null;
    }

    private static bool IsJpeg(string path) =>
        path.EndsWith(".jpg", StringComparison.OrdinalIgnoreCase) ||
        path.EndsWith(".jpeg", StringComparison.OrdinalIgnoreCase);

    private static string FirstLine(string s) => s.Split('\n')[0].Trim();
}
