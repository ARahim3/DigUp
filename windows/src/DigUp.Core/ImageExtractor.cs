// Image extraction facade. Ports ImageExtractor (Extractors.swift:27-72) and
// the screenshot OCR hook (Extractors.swift:74-94).
//
// Windows mapping: ImageIO decode-straight-to-thumbnail becomes WIC
// (System.Windows.Media.Imaging BitmapDecoder with a thumbnail transform, so
// a 48 MP photo is never decoded at full resolution); Vision OCR becomes
// Windows.Media.Ocr (or an ONNX text-recognition model). Both engines are
// injected interfaces below; the WIC/OCR implementations are stubs until wired.

namespace DigUp.Core;

/// <summary>
/// Decodes an image file to a downscaled copy for the model and reports its
/// original dimensions plus EXIF DateTimeOriginal when present.
/// </summary>
public interface IImageDecoder
{
    /// <summary>
    /// Writes a copy fitted within <paramref name="maxPixel"/> pixels to a
    /// fresh file under <paramref name="outputFolder"/> (PNG when
    /// <paramref name="png"/> is true, else JPEG quality ~0.9) and returns its
    /// description. Throws <see cref="ExtractError"/> when the file is not an
    /// image or is smaller than <paramref name="minSide"/> on its long side.
    /// </summary>
    PreparedImage Decode(string sourcePath, int maxPixel, int minSide, string outputFolder, bool png);
}

/// <summary>Reads text off a full-resolution screenshot for keyword search.</summary>
public interface IOcrEngine
{
    string Recognize(string imagePath);

    /// <summary>Whether the engine reads Arabic (gates the OCR retry path).</summary>
    bool ReadsArabic { get; }
}

/// <summary>
/// WIC stub. Wiring plan: BitmapDecoder.Create with BitmapCacheOption.None,
/// take FullSize... no — create a TransformedBitmap / BitmapImage with
// DecodePixelWidth/Height = maxPixel, encode via PngBitmapEncoder or
// JpegBitmapEncoder(QualityLevel 90), read EXIF tag 0x9003 (DateTimeOriginal)
/// via BitmapMetadata. Throws until then.
/// </summary>
public sealed class WicImageDecoderStub : IImageDecoder
{
    public PreparedImage Decode(string sourcePath, int maxPixel, int minSide, string outputFolder, bool png)
    {
        throw new System.NotSupportedException(
            "WIC image decoding is not wired yet: decode " + sourcePath +
            $" to a thumbnail of {maxPixel}px (min side {minSide}) here.");
    }
}

/// <summary>Windows.Media.Ocr stub. Throws until the OCR engine is wired.</summary>
public sealed class WindowsOcrEngineStub : IOcrEngine
{
    public bool ReadsArabic => false;

    public string Recognize(string imagePath)
    {
        throw new System.NotSupportedException(
            "Screenshot OCR is not wired yet (Windows.Media.Ocr).");
    }
}

/// <summary>
/// Image preparation facade. Ports ImageExtractor.prepare/write/fullImage
/// (Extractors.swift:27-72): thumbnails go to the vision encoder, and for
/// screenshots OCR runs on the full-resolution image (small UI text is what
/// screenshots are full of; accurate beats fast).
/// </summary>
public static class ImageExtractor
{
    public const int ScreenshotMaxPixel = 1536;
    public const int PhotoMaxPixel = 1024;

    public static PreparedImage Prepare(
        string path, int maxPixel, int minSide, string folder, bool png, IImageDecoder decoder)
    {
        return decoder.Decode(path, maxPixel, minSide, folder, png);
    }

    /// <summary>OCR text for keyword search; empty when the engine has nothing. Never throws.</summary>
    public static string OcrText(string preparedImagePath, IOcrEngine ocr)
    {
        try
        {
            return ocr.Recognize(preparedImagePath) ?? string.Empty;
        }
        catch
        {
            return string.Empty;
        }
    }

    public static string BuildOutputPath(string folder, bool png)
    {
        return System.IO.Path.Combine(folder, System.Guid.NewGuid().ToString("N") + (png ? ".png" : ".jpg"));
    }
}
