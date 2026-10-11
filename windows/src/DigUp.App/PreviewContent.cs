// What Space previews for a hit, Mac Quick Look style: the thing itself,
// not the excerpt. Pure model (paths, text, moments) so it can be tested
// without a window; PreviewWindow turns it into controls.

using System.IO;
using DigUp.Core;

namespace DigUp.App;

public abstract record PreviewModel
{
    /// <summary>A picture file as-is.</summary>
    public sealed record Image(string Path) : PreviewModel;
    /// <summary>A rendered PDF page (temp file: the window deletes it).</summary>
    public sealed record TempImage(string Path) : PreviewModel;
    /// <summary>Sound or video from seconds in.</summary>
    public sealed record Media(string Path, double Seconds, bool IsVideo) : PreviewModel;
    /// <summary>Words: code around the match, a text file, or an excerpt.
    /// Highlight marks the relevant passage (offset/length, -1 when none).</summary>
    public sealed record Text(string Body, int Highlight = -1, int HighlightLength = 0) : PreviewModel;
    public sealed record None(string Note) : PreviewModel;
}

public static class PreviewContent
{
    private const long MaxTextBytes = 256 * 1024;
    private static readonly string[] TextExtensions =
        [".txt", ".md", ".markdown", ".log", ".csv", ".tsv", ".json", ".xml", ".yml", ".yaml", ".ini", ".cfg"];

    /// <summary>The preview for <paramref name="hit"/>: pictures as pictures,
    /// PDFs as the matched page rendered, sound/video from their moment,
    /// code around the matched lines, small text files whole. The words
    /// carry the relevant passage marked (from <paramref name="query"/>).
    /// Never throws and never returns null; missing files fall back to
    /// the excerpt.</summary>
    public static PreviewModel For(Engine.Hit hit, string pdfiumDll, string query = "")
    {
        string path = hit.Path.Replace('/', Path.DirectorySeparatorChar);
        List<string> tokens = Tokens(query);
        try
        {
            return hit.Kind switch
            {
                "Image" or "Screenshot" when File.Exists(path) => new PreviewModel.Image(path),
                "Video" when File.Exists(path) =>
                    new PreviewModel.Media(path, MainWindow.ParseSeconds(hit.Where), true),
                "Audio" when File.Exists(path) =>
                    new PreviewModel.Media(path, MainWindow.ParseSeconds(hit.Where), false),
                "Pdf" when File.Exists(path) => PdfPage(hit, path, pdfiumDll, tokens),
                "Code" when File.Exists(path) => CodeAt(hit, path, tokens),
                _ => Words(hit, path, tokens),
            };
        }
        catch
        {
            return Fallback(hit, tokens);
        }
    }

    /// <summary>Query words to jump to. The "code:" prefix isn't one.</summary>
    private static List<string> Tokens(string query)
    {
        try { return SearchText.Tokenize(CodeQuery.TextOf(query.Trim()) ?? query); }
        catch { return []; }
    }

    /// <summary>First query word in the body (case-insensitive): the relevant
    /// passage. (-1, 0) when none matches.</summary>
    private static (int At, int Length) Passage(string body, List<string> tokens)
    {
        int at = -1, length = 0;
        foreach (string token in tokens)
        {
            int i = body.IndexOf(token, StringComparison.OrdinalIgnoreCase);
            if (i >= 0 && (at < 0 || i < at)) { at = i; length = token.Length; }
        }
        return (at, length);
    }

    private static PreviewModel PdfPage(Engine.Hit hit, string path, string pdfiumDll, List<string> tokens)
    {
        try
        {
            int page = (int)(MainWindow.ParsePage(hit.Where) ?? 1);
            string png = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".png");
            using var engine = new PdfiumEngine(pdfiumDll);
            using var doc = engine.Open(path);
            doc.RenderPageToPng(Math.Max(0, page - 1), 1400, png);
            return new PreviewModel.TempImage(png);
        }
        catch
        {
            return Fallback(hit, tokens);
        }
    }

    private static PreviewModel CodeAt(Engine.Hit hit, string path, List<string> tokens)
    {
        try
        {
            int line = MainWindow.ParseLine(hit.Where);
            string[] lines = File.ReadAllLines(path);
            int from = Math.Max(1, line - 40), to = Math.Min(lines.Length, line + 40);
            var sb = new System.Text.StringBuilder();
            for (int i = from; i <= to; i++)
                sb.Append(i).Append(": ").AppendLine(lines[i - 1]);
            string body = sb.ToString();
            var (at, length) = Passage(body, tokens);
            return new PreviewModel.Text(body, at, length);
        }
        catch
        {
            return Fallback(hit, tokens);
        }
    }

    private static PreviewModel Words(Engine.Hit hit, string path, List<string> tokens)
    {
        try
        {
            if (File.Exists(path) && TextExtensions.Contains(Path.GetExtension(path).ToLowerInvariant())
                && new FileInfo(path).Length <= MaxTextBytes)
            {
                string body = File.ReadAllText(path);
                var (at, length) = Passage(body, tokens);
                return new PreviewModel.Text(body, at, length);
            }
        }
        catch { }
        return Fallback(hit, tokens);
    }

    private static PreviewModel Fallback(Engine.Hit hit, List<string> tokens)
    {
        if (string.IsNullOrWhiteSpace(hit.Excerpt))
            return new PreviewModel.None("(no words — found by what it shows or says)");
        var (at, length) = Passage(hit.Excerpt, tokens);
        return new PreviewModel.Text(hit.Excerpt, at, length);
    }
}
