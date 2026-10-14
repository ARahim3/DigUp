using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace DigUp.Core;

/// <summary>Character offset range inside an original (un-normalized) string.</summary>
public readonly record struct TextRange(int Start, int Length);

/// <summary>Text the way keyword search keeps it and matches it, so a word is found
/// however it was typed or extracted. Ports SearchText.swift.</summary>
public static class SearchText
{
    /// <summary>NFKC (Arabic presentation forms and ligatures become plain letters,
    /// full-width becomes ASCII, Bengali's two spellings of "ো" become one), invisible
    /// formatting characters dropped (Bengali's zero-width joiners, direction marks),
    /// and Arabic the way people type it: no tatweel, no short-vowel marks, one alef.</summary>
    public static string Normalized(string text)
    {
        // Lone surrogates (PDF encodings, cut pairs) throw below; clean first.
        string compat = TextSanitize.Clean(text).Normalize(NormalizationForm.FormKC);
        var sb = new StringBuilder(compat.Length);
        foreach (var rune in compat.EnumerateRunes())
        {
            int v = rune.Value;
            switch (v)
            {
                case 0x200B:
                    sb.Append(' '); // zero-width space: a word break (Thai, Khmer)
                    break;
                case 0x00AD: // soft hyphen
                case 0x061C:
                case 0xFEFF: // BOM
                    break;
                case >= 0x200C and <= 0x200F: // joiners, direction marks
                case >= 0x202A and <= 0x202E:
                case >= 0x2060 and <= 0x2064:
                case >= 0x2066 and <= 0x2069:
                    break;
                case 0x0640: // tatweel
                case >= 0x064B and <= 0x065F: // harakat
                case 0x0670: // dagger alef
                    break;
                case 0x0622: // alef with hamza or madda, wasla -> alef
                case 0x0623:
                case 0x0625:
                case 0x0671:
                    sb.Append('\u0627');
                    break;
                default:
                    sb.Append(char.ConvertFromUtf32(v));
                    break;
            }
        }
        return sb.ToString();
    }

    /// <summary>True for words of scripts that attach endings to words (Bengali, Hindi,
    /// Arabic): keyword search matches them as prefixes, so "কুমির" finds "কুমিরও"
    /// and "مدرس" finds "مدرسة".</summary>
    public static bool Inflects(string word)
    {
        foreach (var rune in TextSanitize.Clean(word).EnumerateRunes())
        {
            uint v = (uint)rune.Value;
            if ((v >= ScriptRanges.IndicStart && v <= ScriptRanges.IndicEnd) ||
                (v >= ScriptRanges.ArabicStart && v <= ScriptRanges.ArabicEnd))
                return true;
        }
        return false;
    }

    /// <summary>Whether text says something in words: at least a fifth of what isn't
    /// space is letters (marks count, such as Bengali vowel signs). A data dump or a
    /// table of numbers isn't, and gets keyword search only.</summary>
    public static bool HasWords(string text)
    {
        long letters = 0, others = 0;
        foreach (var rune in TextSanitize.Clean(text).EnumerateRunes())
        {
            if (Rune.IsWhiteSpace(rune))
                continue;
            var cat = CharUnicodeInfo.GetUnicodeCategory(rune.Value);
            if (IsLetterOrMark(cat))
                letters++;
            else
                others++;
        }
        return letters > 0 && letters * 4 >= others;
    }

    private static bool IsLetterOrMark(UnicodeCategory cat) =>
        cat is UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter
            or UnicodeCategory.TitlecaseLetter or UnicodeCategory.ModifierLetter
            or UnicodeCategory.OtherLetter or UnicodeCategory.NonSpacingMark
            or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark;

    /// <summary>Where <paramref name="word"/> is in <paramref name="text"/> as keyword
    /// search would find it (normalized, ignoring case and accents), as ranges of the
    /// text as it's written: whole words, and for a word of a language that attaches
    /// endings, the whole word it starts. Caps at 500 matches, like the original.</summary>
    public static List<TextRange> Matches(string word, string text)
    {
        var found = new List<TextRange>();
        string needle = Normalized(word).ToLowerInvariant();
        if (needle.Length == 0 || text.Length == 0)
            return found;

        // Fold the haystack one character at a time, remembering each folded
        // char's origin offset — the same Folded struct as the Swift original,
        // char-based rather than grapheme-based.
        var folded = new StringBuilder(text.Length);
        var origin = new List<int>(text.Length);
        for (int i = 0; i < text.Length; i++)
        {
            string piece = Normalized(text[i].ToString()).ToLowerInvariant();
            foreach (char c in piece)
            {
                folded.Append(c);
                origin.Add(i);
            }
        }

        var compare = CultureInfo.InvariantCulture.CompareInfo;
        const CompareOptions options = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace;
        bool prefix = Inflects(word);
        int searchFrom = 0;
        string hay = folded.ToString();
        while (found.Count < 500 && searchFrom <= hay.Length)
        {
            int hit = compare.IndexOf(hay, needle, searchFrom, hay.Length - searchFrom, options);
            if (hit < 0)
                break;
            searchFrom = hit + Math.Max(needle.Length, 1);
            int first = origin[hit];
            int lastOrigin = origin[Math.Min(hit + Math.Max(needle.Length, 1) - 1, origin.Count - 1)];
            // Map back to whole original chars (a folded char maps to the char it came from).
            int rangeStart = first;
            int rangeEnd = lastOrigin + 1;
            if (rangeStart > 0 && IsWordCharacter(text[rangeStart - 1]))
                continue;
            if (rangeEnd < text.Length && IsWordCharacter(text[rangeEnd]))
            {
                if (!prefix)
                    continue;
                while (rangeEnd < text.Length && IsWordCharacter(text[rangeEnd]))
                    rangeEnd++;
            }
            if (found.Count > 0)
            {
                var last = found[^1];
                if (last.Start < rangeEnd && rangeStart < last.Start + last.Length)
                    continue; // overlaps the previous match
            }
            found.Add(new TextRange(rangeStart, rangeEnd - rangeStart));
        }
        return found;
    }

    /// <summary>One line from <paramref name="text"/> around the first of
    /// <paramref name="terms"/> it has, the terms marked « » as SQLite's snippet()
    /// marks them. Null when none of the terms is in it.</summary>
    public static string? Snippet(string text, IReadOnlyList<string> terms, int words = 12)
    {
        text = TextSanitize.Clean(text); // stored text may predate cleaning
        var marks = new List<TextRange>();
        foreach (var term in terms)
            marks.AddRange(Matches(term, text));
        marks.Sort((a, b) => a.Start.CompareTo(b.Start));
        if (marks.Count == 0)
            return null;

        var first = marks[0];
        int start = first.Start, before = 0;
        while (start > 0 && before < words / 3)
        {
            start--;
            if (char.IsWhiteSpace(text[start]) && start < first.Start &&
                !char.IsWhiteSpace(text[start + 1]))
                before++;
        }
        if (start > 0 || (start < text.Length && char.IsWhiteSpace(text[start])))
            start = Math.Min(start + 1, text.Length);
        int end = first.Start + first.Length, after = 0;
        while (end < text.Length && after < words - before)
        {
            if (char.IsWhiteSpace(text[end]))
                after++;
            end++;
        }

        var sb = new StringBuilder();
        if (start > 0)
            sb.Append('…');
        int cursor = start;
        foreach (var mark in marks)
        {
            int ms = mark.Start, me = mark.Start + mark.Length;
            if (ms >= start && me <= end && ms >= cursor)
            {
                sb.Append(text, cursor, ms - cursor);
                sb.Append('«');
                sb.Append(text, ms, me - ms);
                sb.Append('»');
                cursor = me;
            }
        }
        sb.Append(text, cursor, end - cursor);
        if (end < text.Length)
            sb.Append('…');
        return Regex.Replace(sb.ToString(), @"\s+", " ").Trim();
    }

    /// <summary>Query/content tokens: normalized, lowercased, split on non-alphanumerics.
    /// CJK note: Han/Hangul/Kana characters are Unicode letters, so runs of CJK stay
    /// glued into one C# token here, while FTS5's unicode61 tokenizer emits one token
    /// per CJK character. When building FTS5 patterns for CJK text, split tokens into
    /// per-character (or bigram) phrases instead of quoting the whole token.</summary>
    public static List<string> Tokenize(string text)
    {
        var tokens = new List<string>();
        var current = new StringBuilder();
        foreach (var rune in Normalized(text).ToLowerInvariant().EnumerateRunes())
        {
            char c = (char)(rune.Value <= 0xFFFF ? rune.Value : 0);
            if (rune.Value <= 0xFFFF && char.IsLetterOrDigit(c))
            {
                current.Append(c);
            }
            else if (rune.Value > 0xFFFF && Rune.IsLetterOrDigit(rune))
            {
                current.Append(rune.ToString());
            }
            else if (current.Length > 0)
            {
                if (current.ToString().EnumerateRunes().Count() >= 2)
                    tokens.Add(current.ToString());
                current.Clear();
            }
        }
        if (current.Length > 0 && current.ToString().EnumerateRunes().Count() >= 2)
            tokens.Add(current.ToString());
        return tokens;
    }

    public static bool IsWordCharacter(char c) => char.IsLetterOrDigit(c);
}

public static class ScriptRanges
{
    public const uint IndicStart = 0x0900;
    public const uint IndicEnd = 0x0DFF;
    public const uint ArabicStart = 0x0600;
    public const uint ArabicEnd = 0x06FF;
}

/// <summary>Words to search for in a PDF so its page is among the matches.</summary>
public static class Landmark
{
    /// <param name="texts">The PDF's own text of pages 1 through <paramref name="page"/>.</param>
    /// <returns>The first of <paramref name="words"/> that's on that page, spelled as
    /// the page spells it, preferring one that isn't on an earlier page. Null for page 1
    /// (it opens there anyway), or when none of the words is on it.</returns>
    public static string? Find(int page, IReadOnlyList<string> texts, IReadOnlyList<string> words)
    {
        if (page <= 1 || texts.Count < page)
            return null;
        string target = texts[page - 1];
        var before = new List<string>();
        for (int i = 0; i < page - 1; i++)
            before.Add(SearchText.Normalized(texts[i]).ToLowerInvariant());
        var onPage = new List<string>();
        foreach (var word in words)
        {
            if (word.Length < 3)
                continue;
            var matches = SearchText.Matches(word, target);
            if (matches.Count > 0)
                onPage.Add(target.Substring(matches[0].Start, matches[0].Length));
        }
        foreach (var word in onPage)
        {
            string norm = SearchText.Normalized(word).ToLowerInvariant();
            if (!before.Any(b => b.Contains(norm, StringComparison.Ordinal)))
                return word;
        }
        return onPage.Count > 0 ? onPage[0] : null;
    }
}
