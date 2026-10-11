// How the reference sizes an image for the vision encoder, so llama.cpp
// sees the same pixels. Exact port of Sources/LlamaRuntime/ImageSizing.swift
// (Pillow bicubic, a = -0.5, widened when shrinking, 22-bit fixed point).
// Swift's wrapping &+ &* become unchecked{} here. Checked against the same
// reference vectors as the Mac build.

namespace DigUp.Embed;

internal static class ImageSizing
{
    private const int Precision = 22;

    // transformers' Gemma image processor: fill `budget` soft tokens
    // (each 3x3 patches of 16 px), aspect kept, sides down to multiples of 48.
    // Null when the picture is too thin to embed.
    public static (int H, int W)? TargetSize(int height, int width, int budget)
    {
        const int patch = 16, pooling = 3;
        int maxPatches = budget * pooling * pooling;
        double factor = Math.Sqrt((double)(maxPatches * patch * patch) / (height * width));
        int side = pooling * patch;
        int th = (int)Math.Floor(factor * height / side) * side;
        int tw = (int)Math.Floor(factor * width / side) * side;
        if (th == 0 && tw == 0) return null;
        int maxSide = (maxPatches / (pooling * pooling)) * side;
        if (th == 0) { th = side; tw = Math.Min(width / height * side, maxSide); }
        else if (tw == 0) { tw = side; th = Math.Min(height / width * side, maxSide); }
        return (th, tw);
    }

    public static byte[] ResizeBicubic(byte[] src, int width, int height, int toWidth, int toHeight)
    {
        if (toWidth == width && toHeight == height)
        {
            var copy = new byte[src.Length];
            Buffer.BlockCopy(src, 0, copy, 0, src.Length);
            return copy;
        }
        if (toHeight == height) return Horizontal(src, width, height, toWidth);
        byte[] pass = toWidth == width ? src : Horizontal(src, width, height, toWidth);
        return Vertical(pass, height, toWidth, toHeight);
    }

    private static double Filter(double v)
    {
        double x = Math.Abs(v);
        const double a = -0.5;
        if (x < 1) return ((a + 2) * x - (a + 3)) * x * x + 1;
        if (x < 2) return (((x - 5) * x + 8) * x - 4) * a;
        return 0;
    }

    private static (int[] Bounds, int[] Weights, int Size) Coefficients(int inSize, int outSize)
    {
        double scale = (double)inSize / outSize;
        double fs = Math.Max(scale, 1);
        double support = 2 * fs;
        int size = (int)Math.Ceiling(support) * 2 + 1;
        var bounds = new int[outSize * 2];
        var weights = new int[outSize * size];
        var row = new double[size];
        for (int o = 0; o < outSize; o++)
        {
            double center = (o + 0.5) * scale;
            int first = Math.Max((int)(center - support + 0.5), 0);
            int count = Math.Min((int)(center + support + 0.5), inSize) - first;
            double total = 0;
            for (int x = 0; x < size; x++)
            {
                row[x] = x < count ? Filter((x + first - center + 0.5) / fs) : 0;
                total += row[x];
            }
            for (int x = 0; x < size; x++)
            {
                double w = x < count && total != 0 ? row[x] / total : row[x];
                weights[o * size + x] = (int)(w * (1 << Precision) + (w < 0 ? -0.5 : 0.5));
            }
            bounds[o * 2] = first;
            bounds[o * 2 + 1] = count;
        }
        return (bounds, weights, size);
    }

    private static byte Clip(int v) => (byte)Math.Clamp(v >> Precision, 0, 255);

    private static byte[] Horizontal(byte[] src, int inWidth, int rows, int outWidth)
    {
        var (bounds, weights, size) = Coefficients(inWidth, outWidth);
        var dst = new byte[outWidth * rows * 3];
        unchecked
        {
            for (int y = 0; y < rows; y++)
                for (int x = 0; x < outWidth; x++)
                {
                    int p = (y * inWidth + bounds[x * 2]) * 3;
                    int r = 1 << (Precision - 1), g = r, b = r;
                    for (int k = 0; k < bounds[x * 2 + 1]; k++)
                    {
                        int w = weights[x * size + k];
                        r += src[p] * w;
                        g += src[p + 1] * w;
                        b += src[p + 2] * w;
                        p += 3;
                    }
                    int o = (y * outWidth + x) * 3;
                    dst[o] = Clip(r);
                    dst[o + 1] = Clip(g);
                    dst[o + 2] = Clip(b);
                }
        }
        return dst;
    }

    private static byte[] Vertical(byte[] src, int inHeight, int rowWidth, int outHeight)
    {
        var (bounds, weights, size) = Coefficients(inHeight, outHeight);
        int stride = rowWidth * 3;
        var dst = new byte[stride * outHeight];
        var sums = new int[stride];
        unchecked
        {
            for (int y = 0; y < outHeight; y++)
            {
                for (int i = 0; i < stride; i++) sums[i] = 1 << (Precision - 1);
                for (int k = 0; k < bounds[y * 2 + 1]; k++)
                {
                    int row = (bounds[y * 2] + k) * stride;
                    int w = weights[y * size + k];
                    for (int i = 0; i < stride; i++) sums[i] += src[row + i] * w;
                }
                for (int i = 0; i < stride; i++) dst[y * stride + i] = Clip(sums[i]);
            }
        }
        return dst;
    }
}
