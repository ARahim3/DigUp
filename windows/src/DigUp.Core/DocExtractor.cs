// Document text extraction and chunking. Ports DocExtractor
// (Extractors.swift:161-246): plain text from txt/md directly, HTML by
// stripping tags, rich formats through a converter.
//
// Windows mapping: Cocoa's text system (rtf/docx/doc/odt) becomes
// DocumentFormat.OpenXml for docx plus a conversion step for legacy/odt/rtf.
// Only an RTF fallback is implemented here; docx/doc/odt throw a clear
// ExtractError until the converter is wired, instead of indexing zip garbage.

namespace DigUp.Core;

public static class DocExtractor
{
    /// <summary>Plain text of a document file. Throws ExtractError when unreadable.</summary>
    public static string Text(string path)
    {
        string ext = System.IO.Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        return ext switch
        {
            "html" or "htm" => PlainTextFromHtml(ReadText(path)),
            "rtf" => PlainTextFromRtf(ReadText(path)),
            // Binary formats need a real converter (OpenXml / LibreOffice /
            // Word interop); reading them as text would index zip bytes.
            "docx" or "doc" or "odt" => throw ExtractError.Unreadable(
                $"{ext} converter not wired yet (needs DocumentFormat.OpenXml or equivalent)"),
            _ => ReadText(path),
        };
    }

    internal static string ReadText(string path)
    {
        try
        {
            // Strict UTF-8 first; Latin-1 fallback, as in readText (Extractors.swift:178).
            string text = System.IO.File.ReadAllText(path, System.Text.Encoding.UTF8);
            if (text.Contains('�') && !HasReplacementBytes(path))
            {
                return System.IO.File.ReadAllText(
                    path, System.Text.Encoding.GetEncoding("iso-8859-1"));
            }

            return text;
        }
        catch (System.Exception error) when (error is System.IO.IOException || error is System.UnauthorizedAccessException)
        {
            throw ExtractError.Unreadable(error.Message);
        }
    }

    private static bool HasReplacementBytes(string path)
    {
        // Heuristic: trust UTF-8 unless the raw bytes are not valid UTF-8.
        try
        {
            byte[] raw = System.IO.File.ReadAllBytes(path);
            int sample = System.Math.Min(raw.Length, 8192);
            var utf8 = new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
            utf8.GetString(raw, 0, sample);
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Good enough for search: drops scripts, styles, head and comments, turns
    /// block ends into line breaks, strips tags, decodes entities.
    /// Ports plainText(fromHTML:) (Extractors.swift:186).
    /// </summary>
    public static string PlainTextFromHtml(string html)
    {
        string text = html;
        foreach (string pattern in new[]
                 {
                     @"(?is)<script\b.*?</script\s*>",
                     @"(?is)<style\b.*?</style\s*>",
                     @"(?s)<!--.*?-->",
                     @"(?is)<head\b.*?</head\s*>",
                 })
        {
            text = System.Text.RegularExpressions.Regex.Replace(text, pattern, " ");
        }

        text = System.Text.RegularExpressions.Regex.Replace(
            text, @"(?i)<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)\b[^>]*>", "\n");
        text = System.Text.RegularExpressions.Regex.Replace(text, @"<[^>]+>", " ");

        foreach (var (entity, character) in new (string, string)[]
                 {
                     ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                     ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                     ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
                 })
        {
            text = text.Replace(entity, character);
        }

        text = DecodeNumericEntities(text);
        text = System.Text.RegularExpressions.Regex.Replace(text, @"[ \t]+", " ");
        text = System.Text.RegularExpressions.Regex.Replace(text, @"\s*\n\s*", "\n");
        return text.Trim();
    }

    private static readonly System.Text.RegularExpressions.Regex NumericEntity =
        new(@"&#(x[0-9a-fA-F]+|[0-9]+);", System.Text.RegularExpressions.RegexOptions.Compiled);

    internal static string DecodeNumericEntities(string text)
    {
        if (!text.Contains("&#"))
        {
            return text;
        }

        return NumericEntity.Replace(text, match =>
        {
            string code = match.Groups[1].Value;
            uint value = code.StartsWith("x", System.StringComparison.OrdinalIgnoreCase)
                ? System.Convert.ToUInt32(code.Substring(1), 16)
                : System.Convert.ToUInt32(code, 10);
            try
            {
                return char.ConvertFromUtf32((int)value);
            }
            catch
            {
                return " ";
            }
        });
    }

    /// <summary>
    /// Minimal RTF fallback: paragraph breaks survive, control words and group
    /// braces are dropped. Full fidelity needs a real converter.
    /// </summary>
    public static string PlainTextFromRtf(string rtf)
    {
        string text = rtf.Replace(@"\par", "\n").Replace(@"\line", "\n").Replace(@"\tab", "\t");
        text = System.Text.RegularExpressions.Regex.Replace(text, @"\\[a-zA-Z]+\d*[ ]?", string.Empty);
        text = System.Text.RegularExpressions.Regex.Replace(text, @"\\[^a-zA-Z]", string.Empty);
        text = text.Replace("{", string.Empty).Replace("}", string.Empty);
        text = System.Text.RegularExpressions.Regex.Replace(text, @"[ \t]+", " ");
        text = System.Text.RegularExpressions.Regex.Replace(text, @"\s*\n\s*", "\n");
        return text.Trim();
    }

    /// <summary>
    /// Splits text into ~<paramref name="size"/>-character pieces (~450 tokens)
    /// that overlap a little, breaking at whitespace. Ports chunks
    /// (Extractors.swift:222): size 1800, overlap 200.
    /// </summary>
    public static System.Collections.Generic.IReadOnlyList<string> Chunks(
        string text, int size = 1800, int overlap = 200, int limit = int.MaxValue)
    {
        string clean = System.Text.RegularExpressions.Regex.Replace(text, @"[ \t ]+", " ");
        clean = System.Text.RegularExpressions.Regex.Replace(clean, @"\n\s*\n\s*\n+", "\n\n");
        clean = clean.Trim();
        var chunks = new System.Collections.Generic.List<string>();
        int start = 0;
        while (start < clean.Length && chunks.Count < limit)
        {
            int end = System.Math.Min(start + size, clean.Length);
            if (end < clean.Length)
            {
                int space = clean.LastIndexOfAny(new[] { ' ', '\t', '\n', '\r' }, end - 1, end - start);
                if (space > start && space - start > size / 2)
                {
                    end = space;
                }
            }

            string chunk = clean.Substring(start, end - start).Trim();
            if (chunk.Length > 0)
            {
                chunks.Add(chunk);
            }

            if (end >= clean.Length)
            {
                break;
            }

            int next = System.Math.Max(start, end - overlap);
            if (next <= start)
            {
                next = end;
            }

            while (next < end && !char.IsWhiteSpace(clean[next]))
            {
                next++;
            }

            start = next < end ? next : end;
        }

        return chunks;
    }
}
