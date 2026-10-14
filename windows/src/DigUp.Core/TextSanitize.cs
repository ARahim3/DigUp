// Lone surrogates crash .NET text APIs (string.Normalize, EnumerateRunes)
// with "String contains invalid Unicode code points" — and real files
// contain them: PDF font encodings, OCR garbage, Substring cut mid-pair.
// Swift's String can't hold them, so the Mac original never saw this;
// the C# port must. Every text entry point (index + query) goes through
// Clean, so one poisoned file can never kill a search again.

namespace DigUp.Core;

public static class TextSanitize
{
    /// <summary>The string with every lone surrogate replaced by U+FFFD.
    /// Valid pairs pass through untouched; strings without any surrogate
    /// come back as the same instance (the common case costs one scan).</summary>
    public static string Clean(string text)
    {
        int i = text.IndexOf('\ud800');
        if (i < 0)
        {
            int lo = text.IndexOf('\udc00');
            if (lo < 0)
                return text;
            i = lo;
        }
        char[] buf = text.ToCharArray();
        for (; i < buf.Length; i++)
        {
            char c = buf[i];
            if (c < '\ud800' || c > '\udfff')
                continue;
            bool high = c <= '\udbff';
            bool pair = high && i + 1 < buf.Length && buf[i + 1] >= '\udc00' && buf[i + 1] <= '\udfff';
            if (!pair)
                buf[i] = '\ufffd';
            else
                i++; // keep the pair
        }
        return new string(buf);
    }

    /// <summary>Cuts <paramref name="text"/> to <paramref name="limit"/> chars
    /// without splitting a surrogate pair, then cleans it. For display slices.</summary>
    public static string Cut(string text, int limit)
    {
        if (text.Length <= limit)
            return Clean(text);
        int end = limit;
        if (end > 0 && char.IsHighSurrogate(text[end - 1]) &&
            end < text.Length && char.IsLowSurrogate(text[end]))
            end--;
        return Clean(text.Substring(0, end));
    }
}
