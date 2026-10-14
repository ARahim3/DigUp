using System.Buffers.Binary;
using System.IO.MemoryMappedFiles;

namespace DigUp.Core;

/// <summary>Vectors are stored as 768 × float16 (1.5 KB each), kept that way in memory
/// too, and scored as float32. Ports Vectors.swift.</summary>
public static class Vectors
{
    public const int Dimension = 768;
    public const int BytesPerVector = Dimension * 2;

    /// <summary>L2-normalized float vector → 768 × float16 blob for the <c>vec</c> column.</summary>
    public static byte[] ToHalfBlob(IReadOnlyList<float> vector)
    {
        if (vector.Count != Dimension)
            throw new ArgumentOutOfRangeException(nameof(vector), $"expected {Dimension} floats");
        var bytes = new byte[BytesPerVector];
        for (int i = 0; i < Dimension; i++)
            BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(i * 2, 2),
                BitConverter.HalfToUInt16Bits((Half)vector[i]));
        return bytes;
    }

    public static float[] FromHalfBlob(byte[] blob)
    {
        if (blob.Length != BytesPerVector)
            throw new ArgumentOutOfRangeException(nameof(blob), $"expected {BytesPerVector} bytes");
        var vector = new float[Dimension];
        for (int i = 0; i < Dimension; i++)
            vector[i] = (float)BitConverter.UInt16BitsToHalf(
                BinaryPrimitives.ReadUInt16LittleEndian(blob.AsSpan(i * 2, 2)));
        return vector;
    }

    /// <summary>Cosine similarity. Stored vectors are L2-normalized, so for a
    /// normalized query this is the dot product.</summary>
    public static float Cosine(ReadOnlySpan<float> a, ReadOnlySpan<float> b)
    {
        double dot = 0;
        for (int i = 0; i < Dimension; i++)
            dot += (double)a[i] * b[i];
        return (float)dot;
    }
}

/// <summary>The vectors search scores, as stored (float16), plus room to turn
/// <see cref="BlockRows"/> of them into float32 at a time. Backed by a pagefile
/// MemoryMappedFile so releasing it really frees it (the Swift original uses mmap
/// for the same reason: freed malloc blocks stayed in the footprint).</summary>
public sealed class VectorStore : IDisposable
{
    public const int BlockRows = 1024;

    private readonly MemoryMappedFile _file;
    private readonly MemoryMappedViewAccessor _accessor;
    private readonly Half[] _scratch = new Half[BlockRows * Vectors.Dimension];
    private bool _disposed;

    public int Rows { get; }

    private VectorStore(int rows, MemoryMappedFile file, MemoryMappedViewAccessor accessor)
    {
        Rows = rows;
        _file = file;
        _accessor = accessor;
    }

    public static VectorStore? Create(int rows)
    {
        if (rows <= 0)
            return null;
        long capacity = (long)rows * Vectors.BytesPerVector;
        var file = MemoryMappedFile.CreateNew(null, capacity, MemoryMappedFileAccess.ReadWrite);
        try
        {
            var accessor = file.CreateViewAccessor(0, capacity, MemoryMappedFileAccess.ReadWrite);
            return new VectorStore(rows, file, accessor);
        }
        catch
        {
            file.Dispose();
            throw;
        }
    }

    public void SetRow(int row, byte[] blob)
    {
        if (blob.Length != Vectors.BytesPerVector)
            throw new ArgumentOutOfRangeException(nameof(blob));
        ObjectDisposedException.ThrowIf(_disposed, this);
        _accessor.WriteArray((long)row * Vectors.BytesPerVector, blob, 0, blob.Length);
    }

    public void GetRow(int row, Span<float> destination)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var halves = new Half[Vectors.Dimension];
        _accessor.ReadArray((long)row * Vectors.BytesPerVector, halves, 0, halves.Length);
        for (int i = 0; i < halves.Length; i++)
            destination[i] = (float)halves[i];
    }

    /// <summary>Converts <paramref name="rowCount"/> rows starting at
    /// <paramref name="startRow"/> into float32 in <paramref name="destination"/>
    /// (room for at least <c>rowCount × Dimension</c> floats).</summary>
    public void CopyBlockAsFloat(int startRow, int rowCount, float[] destination)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        _accessor.ReadArray((long)startRow * Vectors.BytesPerVector,
            _scratch, 0, rowCount * Vectors.Dimension);
        for (int i = 0; i < rowCount * Vectors.Dimension; i++)
            destination[i] = (float)_scratch[i];
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        _accessor.Dispose();
        _file.Dispose();
    }
}

/// <summary>Per-modality normalization: each vector's cosine similarity minus the
/// average of its modality (text, image and audio vectors can sit at slightly
/// different levels for the same query), in standard deviations of all of them
/// together. Ports Searcher.meaning / modalityMeans.</summary>
public static class VectorMath
{
    /// <summary>The average score of each modality for this query. Small groups
    /// (&lt; 20 vectors) take the average of all.</summary>
    public static Dictionary<Modality, double> ModalityMeans(
        IReadOnlyList<float> scores, IReadOnlyList<Modality> modality,
        IReadOnlyList<bool>? setsScale = null)
    {
        var sum = new Dictionary<Modality, double>();
        var count = new Dictionary<Modality, int>();
        for (int row = 0; row < scores.Count; row++)
        {
            if (setsScale is not null && !setsScale[row])
                continue;
            sum[modality[row]] = sum.GetValueOrDefault(modality[row]) + scores[row];
            count[modality[row]] = count.GetValueOrDefault(modality[row]) + 1;
        }
        double total = 0;
        int totalCount = 0;
        foreach (var kv in sum)
        {
            total += kv.Value;
            totalCount += count[kv.Key];
        }
        double all = total / Math.Max(totalCount, 1);
        var output = new Dictionary<Modality, double>();
        foreach (var m in ModalityStrings.All)
        {
            if (count.TryGetValue(m, out int n) && n >= 20)
                output[m] = sum[m] / n;
            else
                output[m] = all;
        }
        return output;
    }

    /// <summary>This query's meaning scores: z-scores of modality-centered cosines.
    /// The scale comes from the vectors in <paramref name="setsScale"/> (all by
    /// default); later pages of long files are scored on it but don't move it.</summary>
    public static double[] Meaning(
        IReadOnlyList<float> scores, IReadOnlyList<Modality> modality,
        IReadOnlyList<bool>? setsScale = null)
    {
        var means = ModalityMeans(scores, modality, setsScale);
        var centered = new double[scores.Count];
        for (int i = 0; i < scores.Count; i++)
            centered[i] = scores[i] - means.GetValueOrDefault(modality[i]);
        double count = 0, sum = 0;
        for (int i = 0; i < centered.Length; i++)
        {
            if (setsScale is not null && !setsScale[i])
                continue;
            count++;
            sum += centered[i];
        }
        double mean = sum / Math.Max(count, 1);
        double squares = 0;
        for (int i = 0; i < centered.Length; i++)
        {
            if (setsScale is not null && !setsScale[i])
                continue;
            squares += (centered[i] - mean) * (centered[i] - mean);
        }
        double deviation = Math.Max(Math.Sqrt(squares / Math.Max(count, 1)), 0.02);
        var z = new double[centered.Length];
        for (int i = 0; i < centered.Length; i++)
            z[i] = (centered[i] - mean) / deviation;
        return z;
    }
}
