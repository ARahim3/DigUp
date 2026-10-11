// PDF extraction facade. Ports PDFExtractor (Extractors.swift:96-159) and
// PageTextProblem (SearchText.swift:164-212).
//
// Windows mapping: PDFKit becomes Pdfium (pdfium.dll, path injected — never
// hard-coded). Text-layer policy is unchanged: pages with enough real text
// become text; scans and slides are rendered; garbled layers are replaced by
// OCR (lost Arabic letters) or by the rendered page plus a meaning vector of
// the garbled words (glyph-order Indic text OCR cannot read).

namespace DigUp.Core;

/// <summary>What is wrong with a page's text layer. Ports PageTextProblem (SearchText.swift:165).</summary>
public enum PageTextProblem
{
    /// <summary>Bengali/Hindi read in glyph order: used as a picture instead.</summary>
    GlyphOrder,

    /// <summary>Arabic letters lost at lam ligatures: read again by OCR.</summary>
    LostLetters,
}

public static class PageTextProblemCheck
{
    private const uint ArabicAlef = 0x0627;
    private const uint Replacement = 0xFFFD;

    public static PageTextProblem? Check(string text)
    {
        string normalized = text.Normalize(System.Text.NormalizationForm.FormC);
        int vowelSigns = 0, misplaced = 0, lostLetters = 0;
        uint previous = 0x20, beforePrevious = 0x20;
        foreach (char c in normalized)
        {
            uint value = c;
            if (IsIndicVowelSign(value))
            {
                vowelSigns++;
                if (!IsIndicConsonantOrNukta(previous))
                {
                    misplaced++;
                }
            }

            if (beforePrevious == ArabicAlef
                && (previous == '?' || previous == '.' || previous == Replacement)
                && value >= 0x0600 && value <= 0x06FF
                && IsAlphabetic(c))
            {
                lostLetters++;
            }

            beforePrevious = previous;
            previous = value;
        }

        if (vowelSigns >= 10 && misplaced * 20 >= vowelSigns)
        {
            return PageTextProblem.GlyphOrder;
        }

        if (lostLetters >= 2)
        {
            return PageTextProblem.LostLetters;
        }

        return null;
    }

    public static bool ContainsArabic(string text)
    {
        foreach (char c in text)
        {
            if (c >= 0x0600 && c <= 0x06FF)
            {
                return true;
            }
        }

        return false;
    }

    private static bool IsAlphabetic(char c)
    {
        return System.Globalization.CharUnicodeInfo.GetUnicodeCategory(c) switch
        {
            System.Globalization.UnicodeCategory.UppercaseLetter => true,
            System.Globalization.UnicodeCategory.LowercaseLetter => true,
            System.Globalization.UnicodeCategory.TitlecaseLetter => true,
            System.Globalization.UnicodeCategory.ModifierLetter => true,
            System.Globalization.UnicodeCategory.OtherLetter => true,
            _ => false,
        };
    }

    private static bool IsIndicVowelSign(uint value) => value switch
    {
        >= 0x09BE and <= 0x09C4 => true,
        0x09C7 or 0x09C8 or 0x09CB or 0x09CC or 0x09D7 or 0x09E2 or 0x09E3 => true,
        0x093A or 0x093B => true,
        >= 0x093E and <= 0x094C => true,
        0x094E or 0x094F => true,
        >= 0x0955 and <= 0x0957 => true,
        0x0962 or 0x0963 => true,
        _ => false,
    };

    private static bool IsIndicConsonantOrNukta(uint value) => value switch
    {
        >= 0x0995 and <= 0x09B9 => true,
        0x09BC or 0x09CE or 0x09DC or 0x09DD or 0x09DF or 0x09F0 or 0x09F1 => true,
        >= 0x0915 and <= 0x0939 => true,
        0x093C => true,
        >= 0x0958 and <= 0x095F => true,
        >= 0x0979 and <= 0x097F => true,
        _ => false,
    };
}

/// <summary>One open PDF document. One instance per extraction; not thread-safe.</summary>
public abstract class PdfOpenedDocument : System.IDisposable
{
    public abstract int PageCount { get; }
    public abstract bool IsLocked { get; }
    public abstract string? Title { get; }
    public abstract string GetPageText(int index0);
    public abstract void RenderPageToPng(int index0, int pixels, string outputPath);
    public abstract void Dispose();
}

/// <summary>PDF engine. The Pdfium native library path is injected; there is no default.</summary>
public interface IPdfEngine
{
    PdfOpenedDocument Open(string path);
}

/// <summary>
/// Pdfium over P/Invoke (pdfium.dll, path injected — never hard-coded).
/// Text comes from the text layer, scans render to PNG; the dll is Chromium's
/// Pdfium (BSD-3, see the Builder Guide for the pinned build).
/// All native calls hold one process-wide lock: extraction runs PDFs in
/// parallel and sharing one engine instance across threads must be boring.
/// </summary>
public sealed class PdfiumEngine : IPdfEngine, System.IDisposable
{
    private static readonly object Gate = new();
    private static IntPtr _lib;
    private static bool _inited;
    private static string? _loadedPath;

    public PdfiumEngine(string pdfiumDllPath)
    {
        if (string.IsNullOrWhiteSpace(pdfiumDllPath))
        {
            throw new System.ArgumentException("A Pdfium DLL path must be injected.", nameof(pdfiumDllPath));
        }

        PdfiumDllPath = pdfiumDllPath;
    }

    public string PdfiumDllPath { get; }

    /// <summary>Nothing per instance (the native library lives as long as
    /// the process); present so callers can scope an engine per document.</summary>
    public void Dispose()
    {
    }

    public PdfOpenedDocument Open(string path)
    {
        EnsureLoaded();
        byte[] bytes;
        try
        {
            bytes = System.IO.File.ReadAllBytes(path);
        }
        catch (System.Exception error) when (error is System.IO.IOException || error is System.UnauthorizedAccessException)
        {
            throw ExtractError.Unreadable(error.Message);
        }

        lock (Gate)
        {
            var handle = System.Runtime.InteropServices.GCHandle.Alloc(bytes,
                System.Runtime.InteropServices.GCHandleType.Pinned);
            IntPtr doc = Native.FPDF_LoadMemDocument(handle.AddrOfPinnedObject(), bytes.Length, null);
            if (doc == IntPtr.Zero)
            {
                handle.Free();
                ulong err = Native.FPDF_GetLastError();
                if (err == Native.FPDF_ERR_PASSWORD)
                {
                    return new PdfiumDoc(IntPtr.Zero, null, locked: true);
                }

                throw ExtractError.Unreadable("not a PDF Pdfium can open (" + Describe(err) + ")");
            }

            return new PdfiumDoc(doc, handle, locked: false);
        }
    }

    private void EnsureLoaded()
    {
        lock (Gate)
        {
            if (_inited && _loadedPath == PdfiumDllPath)
            {
                return;
            }

            if (!System.IO.File.Exists(PdfiumDllPath))
            {
                throw ExtractError.Unreadable($"pdfium.dll is missing ({PdfiumDllPath}); reinstall DigUp.");
            }

            // Pin the exact file first: later DllImport("pdfium.dll") calls
            // bind to this loaded module instead of searching.
            if (_lib != IntPtr.Zero)
            {
                System.Runtime.InteropServices.NativeLibrary.Free(_lib);
                _lib = IntPtr.Zero;
                _inited = false;
            }

            _lib = System.Runtime.InteropServices.NativeLibrary.Load(PdfiumDllPath);
            _loadedPath = PdfiumDllPath;
            Native.FPDF_InitLibrary();
            _inited = true;
        }
    }

    private static string Describe(ulong err) => err switch
    {
        Native.FPDF_ERR_FORMAT => "broken or not a PDF",
        Native.FPDF_ERR_FILE => "can't be read",
        Native.FPDF_ERR_SECURITY => "unsupported encryption",
        Native.FPDF_ERR_PAGE => "pages are broken",
        _ => $"error {err}",
    };

    private static class Native
    {
        public const ulong FPDF_ERR_PASSWORD = 4;
        public const ulong FPDF_ERR_FORMAT = 3;
        public const ulong FPDF_ERR_FILE = 2;
        public const ulong FPDF_ERR_SECURITY = 5;
        public const ulong FPDF_ERR_PAGE = 6;
        private const string Dll = "pdfium.dll";

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern void FPDF_InitLibrary();

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern IntPtr FPDF_LoadMemDocument(IntPtr data, int size,
            [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPStr)] string? password);

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern ulong FPDF_GetLastError();

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern int FPDF_GetPageCount(IntPtr doc);

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern IntPtr FPDF_LoadPage(IntPtr doc, int index);

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern void FPDF_ClosePage(IntPtr page);

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern float FPDF_GetPageWidthF(IntPtr page);

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern float FPDF_GetPageHeightF(IntPtr page);

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern void FPDF_CloseDocument(IntPtr doc);

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern IntPtr FPDFText_LoadPage(IntPtr page);

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern void FPDFText_ClosePage(IntPtr textPage);

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern int FPDFText_CountChars(IntPtr textPage);

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern int FPDFText_GetText(IntPtr textPage, int start, int count,
            [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPArray)] ushort[] result);

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern ulong FPDF_GetMetaText(IntPtr doc,
            [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPArray)] byte[] tag,
            IntPtr buffer, ulong buflen);

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern IntPtr FPDFBitmap_CreateEx(int width, int height, int format, IntPtr firstScan, int stride);

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern bool FPDFBitmap_FillRect(IntPtr bitmap, int left, int top, int width, int height, uint color);

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern void FPDF_RenderPageBitmap(IntPtr bitmap, IntPtr page,
            int startX, int startY, int sizeX, int sizeY, int rotate, int flags);

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern IntPtr FPDFBitmap_GetBuffer(IntPtr bitmap);

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern int FPDFBitmap_GetStride(IntPtr bitmap);

        [System.Runtime.InteropServices.DllImport(Dll)]
        public static extern void FPDFBitmap_Destroy(IntPtr bitmap);
    }

    private sealed class PdfiumDoc : PdfOpenedDocument
    {
        private IntPtr _doc;
        private System.Runtime.InteropServices.GCHandle _pin;
        private readonly bool _locked;
        private bool _disposed;

        public PdfiumDoc(IntPtr doc, System.Runtime.InteropServices.GCHandle? pin, bool locked)
        {
            _doc = doc;
            if (pin.HasValue)
            {
                _pin = pin.Value;
            }

            _locked = locked;
        }

        public override int PageCount
        {
            get
            {
                ThrowIfLocked();
                lock (Gate) { return Native.FPDF_GetPageCount(_doc); }
            }
        }

        public override bool IsLocked => _locked;

        public override string? Title
        {
            get
            {
                ThrowIfLocked();
                lock (Gate)
                {
                    byte[] tag = [(byte)'T', (byte)'i', (byte)'t', (byte)'l', (byte)'e', 0];
                    ulong size = Native.FPDF_GetMetaText(_doc, tag, IntPtr.Zero, 0);
                    if (size < 2)
                    {
                        return null;
                    }

                    IntPtr buf = System.Runtime.InteropServices.Marshal.AllocHGlobal((IntPtr)(size + 2));
                    try
                    {
                        Native.FPDF_GetMetaText(_doc, tag, buf, size);
                        var raw = new byte[(int)size];
                        System.Runtime.InteropServices.Marshal.Copy(buf, raw, 0, raw.Length);
                        string title = System.Text.Encoding.Unicode.GetString(raw);
                        return string.IsNullOrWhiteSpace(title) ? null : title.TrimEnd('\0').Trim();
                    }
                    finally
                    {
                        System.Runtime.InteropServices.Marshal.FreeHGlobal(buf);
                    }
                }
            }
        }

        public override string GetPageText(int index0)
        {
            ThrowIfLocked();
            lock (Gate)
            {
                IntPtr page = Native.FPDF_LoadPage(_doc, index0);
                if (page == IntPtr.Zero)
                {
                    throw ExtractError.Unreadable($"page {index0 + 1} won't open");
                }

                try
                {
                    IntPtr tp = Native.FPDFText_LoadPage(page);
                    if (tp == IntPtr.Zero)
                    {
                        return string.Empty;
                    }

                    try
                    {
                        int count = Native.FPDFText_CountChars(tp);
                        if (count <= 0)
                        {
                            return string.Empty;
                        }

                        var buf = new ushort[count + 1];
                        int got = Native.FPDFText_GetText(tp, 0, count, buf);
                        int n = System.Math.Max(0, System.Math.Min(got, count));
                        return new string(System.Linq.Enumerable.Select(
                            System.Linq.Enumerable.Take(buf, n), c => (char)c).ToArray());
                    }
                    finally
                    {
                        Native.FPDFText_ClosePage(tp);
                    }
                }
                finally
                {
                    Native.FPDF_ClosePage(page);
                }
            }
        }

        public override void RenderPageToPng(int index0, int pixels, string outputPath)
        {
            ThrowIfLocked();
            byte[] png;
            lock (Gate)
            {
                IntPtr page = Native.FPDF_LoadPage(_doc, index0);
                if (page == IntPtr.Zero)
                {
                    throw ExtractError.Unreadable($"page {index0 + 1} won't render");
                }

                try
                {
                    float w = Native.FPDF_GetPageWidthF(page);
                    float h = Native.FPDF_GetPageHeightF(page);
                    if (w <= 0 || h <= 0 || w > 100000 || h > 100000)
                    {
                        throw ExtractError.Unreadable($"page {index0 + 1} has a nonsense size");
                    }

                    double scale = pixels / System.Math.Max(w, h);
                    int bw = System.Math.Max(1, (int)System.Math.Round(w * scale));
                    int bh = System.Math.Max(1, (int)System.Math.Round(h * scale));
                    if ((long)bw * bh > 64_000_000)
                    {
                        throw ExtractError.Unreadable($"page {index0 + 1} renders too big");
                    }

                    IntPtr bmp = Native.FPDFBitmap_CreateEx(bw, bh, 4 /* BGRA */, IntPtr.Zero, 0);
                    if (bmp == IntPtr.Zero)
                    {
                        throw ExtractError.Unreadable($"page {index0 + 1} has no room to render");
                    }

                    try
                    {
                        Native.FPDFBitmap_FillRect(bmp, 0, 0, bw, bh, 0xFFFFFFFF);
                        Native.FPDF_RenderPageBitmap(bmp, page, 0, 0, bw, bh, 0, 1 /* with notes */);
                        IntPtr src = Native.FPDFBitmap_GetBuffer(bmp);
                        int stride = Native.FPDFBitmap_GetStride(bmp);
                        if (src == IntPtr.Zero || stride < bw * 4)
                        {
                            throw ExtractError.Unreadable($"page {index0 + 1} rendered nothing");
                        }

                        var raw = new byte[stride * bh];
                        System.Runtime.InteropServices.Marshal.Copy(src, raw, 0, raw.Length);
                        png = ToPng(raw, stride, bw, bh);
                    }
                    finally
                    {
                        Native.FPDFBitmap_Destroy(bmp);
                    }
                }
                finally
                {
                    Native.FPDF_ClosePage(page);
                }
            }

            try
            {
                System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(outputPath)!);
                System.IO.File.WriteAllBytes(outputPath, png);
            }
            catch (System.Exception error) when (error is System.IO.IOException || error is System.UnauthorizedAccessException)
            {
                throw ExtractError.Unreadable("can't write the page picture: " + error.Message);
            }
        }

        // Pdfium gives BGRA bytes, which is exactly GDI+'s 32-bit layout.
        private static byte[] ToPng(byte[] raw, int stride, int w, int h)
        {
            using var bmp = new System.Drawing.Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            var rect = new System.Drawing.Rectangle(0, 0, w, h);
            var data = bmp.LockBits(rect, System.Drawing.Imaging.ImageLockMode.WriteOnly,
                System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            try
            {
                if (data.Stride == stride)
                {
                    System.Runtime.InteropServices.Marshal.Copy(raw, 0, data.Scan0, raw.Length);
                }
                else
                {
                    for (int y = 0; y < h; y++)
                    {
                        System.Runtime.InteropServices.Marshal.Copy(raw, y * stride,
                            data.Scan0 + y * data.Stride, w * 4);
                    }
                }
            }
            finally
            {
                bmp.UnlockBits(data);
            }

            using var ms = new System.IO.MemoryStream();
            bmp.Save(ms, System.Drawing.Imaging.ImageFormat.Png);
            return ms.ToArray();
        }

        private void ThrowIfLocked()
        {
            if (_locked)
            {
                throw ExtractError.Locked();
            }

            System.ObjectDisposedException.ThrowIf(_disposed, this);
        }

        public override void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            lock (Gate)
            {
                if (_doc != IntPtr.Zero)
                {
                    Native.FPDF_CloseDocument(_doc);
                    _doc = IntPtr.Zero;
                }
            }

            if (_pin.IsAllocated)
            {
                _pin.Free();
            }
        }
    }
}

/// <summary>
/// Reads pages in <paramref name="read"/> (0-based, already clamped by the
/// caller to [0, min(total, MaxPages))). Ports PDFExtractor.pages
/// (Extractors.swift:112-151). The first-30-pages fast path and the 5000-page
/// cap live in DefaultExtractor (IndexOptions.PdfStep/BigPdfPages/MaxPages).
/// </summary>
public static class PdfExtractor
{
    /// <summary>Pixels of the square a rendered page is fitted into. (Indexer.swift:392)</summary>
    public const int RenderPixels = 1400;

    /// <summary>Render size for the Arabic OCR retry. (Extractors.swift:124)</summary>
    public const int OcrRenderPixels = 2000;

    public static (System.Collections.Generic.IReadOnlyList<PdfPage> Pages, int Total, string? Title) Pages(
        string path,
        JobStep read,
        int minText,
        int renderPixels,
        string folder,
        IPdfEngine engine,
        IOcrEngine? ocr)
    {
        using var doc = engine.Open(path);
        if (doc.IsLocked)
        {
            throw ExtractError.Locked();
        }

        int total = doc.PageCount;
        var pages = new System.Collections.Generic.List<PdfPage>();
        for (int index = read.Start; index < read.EndExclusive && index < total; index++)
        {
            string text = (doc.GetPageText(index) ?? string.Empty).Trim();
            string? garbled = null;
            var problem = PageTextProblemCheck.Check(text);
            if (problem == PageTextProblem.LostLetters)
            {
                // OCR replaces the layer only when it reads real Arabic;
                // otherwise the layer stays as it is. (Extractors.swift:122)
                string? ocrText = TryOcrPage(doc, index, ocr);
                if (ocrText != null
                    && ocrText.Length >= minText
                    && PageTextProblemCheck.Check(ocrText) == null
                    && PageTextProblemCheck.ContainsArabic(ocrText))
                {
                    pages.Add(new PdfPage(index + 1, ocrText, null, Ocr: true));
                    continue;
                }

                if (text.Length >= minText)
                {
                    pages.Add(new PdfPage(index + 1, text, null));
                    continue;
                }
            }
            else if (problem == PageTextProblem.GlyphOrder)
            {
                garbled = text;
                text = string.Empty;
            }
            else if (text.Length >= minText)
            {
                pages.Add(new PdfPage(index + 1, text, null));
                continue;
            }

            string outPath = System.IO.Path.Combine(folder, System.Guid.NewGuid().ToString("N") + ".png");
            doc.RenderPageToPng(index, renderPixels, outPath);
            pages.Add(new PdfPage(index + 1, text, outPath, Garbled: garbled));
        }

        return (pages, total, doc.Title);
    }

    private static string? TryOcrPage(PdfOpenedDocument doc, int index0, IOcrEngine? ocr)
    {
        if (ocr == null || !ocr.ReadsArabic)
        {
            return null;
        }

        try
        {
            string temp = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(), System.Guid.NewGuid().ToString("N") + ".png");
            try
            {
                doc.RenderPageToPng(index0, OcrRenderPixels, temp);
                return ocr.Recognize(temp)?.Trim();
            }
            finally
            {
                try
                {
                    System.IO.File.Delete(temp);
                }
                catch
                {
                    // Best effort.
                }
            }
        }
        catch
        {
            return null;
        }
    }
}
