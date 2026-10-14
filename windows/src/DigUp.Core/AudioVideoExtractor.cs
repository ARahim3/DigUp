// Audio and video extraction through an injected FFmpeg build. Ports
// AudioExtractor / VideoExtractor / MediaInfo (MediaExtractors.swift:28-165).
//
// Windows mapping: AVFoundation becomes FFmpeg CLI (no native AVFoundation
// on Windows). Policy is unchanged: 16 kHz mono, ≤30 s windows every 25 s,
// silence skipped (~-50 dBFS), streaming memory of one window; keyframes
// sampled every FrameInterval seconds with one kept per shot (8×8 average
// hash within 4 bits), capped at MaxFrames.
//
// No FFmpeg path is hard-coded: FFmpegPaths must be injected (bundled exe
// location comes from app configuration). Pure functions (hashing, RMS, WAV
// writing, shot dedupe, argument building) are separated so they work and are
// testable without FFmpeg present.

namespace DigUp.Core;

/// <summary>
/// Paths to the FFmpeg/ffprobe executables. Injected by the host (e.g. a
/// bundled tools folder); validated on use, never defaulted.
/// </summary>
public sealed record FFmpegPaths(string FFmpegExe, string FFprobeExe)
{
    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(FFmpegExe) || string.IsNullOrWhiteSpace(FFprobeExe))
        {
            throw ExtractError.Unreadable("FFmpeg paths were not injected");
        }

        if (!System.IO.File.Exists(FFmpegExe))
        {
            throw ExtractError.Unreadable($"ffmpeg not found: {FFmpegExe}");
        }

        if (!System.IO.File.Exists(FFprobeExe))
        {
            throw ExtractError.Unreadable($"ffprobe not found: {FFprobeExe}");
        }
    }
}

public static class AudioVideoExtractor
{
    public const double SampleRate = 16_000.0;

    /// <summary>≈ −50 dBFS: silence is not worth a vector. (MediaExtractors.swift:54)</summary>
    public const double SilenceRmsThreshold = 0.003;

    /// <summary>Tail shorter than this is dropped. (MediaExtractors.swift:34)</summary>
    public const double TailMinimumSeconds = 2.0;

    public const int FrameMaxPixel = 1024;
    public const int MaxFrames = 1200;

    // MARK: Pure functions (no FFmpeg needed)

    /// <summary>Sample step: at least the interval, tightened so frames fit MaxFrames.</summary>
    public static double ComputeStep(double duration, double interval, int maxFrames = MaxFrames)
    {
        return System.Math.Max(interval, duration / maxFrames);
    }

    /// <summary>Candidate sample times from min(0.5, duration/2) by step. (MediaExtractors.swift:120)</summary>
    public static System.Collections.Generic.IReadOnlyList<double> CandidateTimes(double duration, double step)
    {
        var times = new System.Collections.Generic.List<double>();
        for (double t = System.Math.Min(0.5, duration / 2); t < duration; t += step)
        {
            times.Add(t);
        }

        return times;
    }

    /// <summary>8×8 average hash of 64 grayscale bytes.</summary>
    public static ulong AverageHash(byte[] gray64)
    {
        if (gray64.Length != 64)
        {
            throw new System.ArgumentException("Need exactly 64 grayscale bytes.", nameof(gray64));
        }

        long sum = 0;
        foreach (byte b in gray64)
        {
            sum += b;
        }

        long mean = sum / 64;
        ulong hash = 0;
        for (int i = 0; i < 64; i++)
        {
            if (gray64[i] > mean)
            {
                hash |= 1UL << i;
            }
        }

        return hash;
    }

    public static int HashDistance(ulong a, ulong b)
    {
        return System.Numerics.BitOperations.PopCount(a ^ b);
    }

    /// <summary>
    /// Keeps one frame per shot: a frame within 4 hash bits of the previous
    /// kept frame only extends it. Each kept frame stands for the stretch
    /// until the next one. (MediaExtractors.swift:129-136)
    /// </summary>
    public static System.Collections.Generic.IReadOnlyList<(int Index, double Start, double End)> DedupeShots(
        System.Collections.Generic.IReadOnlyList<double> times,
        System.Collections.Generic.IReadOnlyList<ulong> hashes,
        double duration)
    {
        var kept = new System.Collections.Generic.List<(int, double, double)>();
        ulong? lastHash = null;
        for (int i = 0; i < times.Count && i < hashes.Count; i++)
        {
            if (lastHash.HasValue && HashDistance(hashes[i], lastHash.Value) <= 4)
            {
                continue;
            }

            lastHash = hashes[i];
            kept.Add((i, System.Math.Max(0, times[i]), duration));
        }

        for (int i = 0; i + 1 < kept.Count; i++)
        {
            kept[i] = (kept[i].Item1, kept[i].Item2, times[kept[i + 1].Item1]);
        }

        return kept;
    }

    public static double Rms(short[] samples, int offset, int count)
    {
        if (count <= 0)
        {
            return 0;
        }

        double sum = 0;
        for (int i = 0; i < count; i++)
        {
            double v = samples[offset + i] / 32768.0;
            sum += v * v;
        }

        return System.Math.Sqrt(sum / count);
    }

    /// <summary>Writes 16 kHz mono 16-bit little-endian WAV. (MediaExtractors.swift:87)</summary>
    public static void WriteWav(string path, short[] samples, int offset, int count)
    {
        using var stream = System.IO.File.OpenWrite(path);
        using var writer = new System.IO.BinaryWriter(stream);
        uint rate = (uint)SampleRate;
        writer.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));
        writer.Write((uint)(36 + count * 2));
        writer.Write(System.Text.Encoding.ASCII.GetBytes("WAVE"));
        writer.Write(System.Text.Encoding.ASCII.GetBytes("fmt "));
        writer.Write(16u);
        writer.Write((ushort)1);
        writer.Write((ushort)1);
        writer.Write(rate);
        writer.Write(rate * 2);
        writer.Write((ushort)2);
        writer.Write((ushort)16);
        writer.Write(System.Text.Encoding.ASCII.GetBytes("data"));
        writer.Write((uint)(count * 2));
        for (int i = 0; i < count; i++)
        {
            writer.Write(samples[offset + i]);
        }
    }

    // MARK: FFmpeg argument builders (invariant culture; quoted paths)

    public static string BuildPcmArgs(string inputPath) =>
        $"-hide_banner -v error -i {Quote(inputPath)} -ac 1 -ar {(int)SampleRate} -f s16le -acodec pcm_s16le pipe:1";

    public static string BuildProbeArgs(string inputPath) =>
        $"-v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 {Quote(inputPath)}";

    public static string BuildStreamCheckArgs(string inputPath, char stream) =>
        $"-v error -select_streams {stream} -show_entries stream=index -of csv=p=0 {Quote(inputPath)}";

    public static string BuildCandidatesArgs(string inputPath, double fps, int maxPixel, string outputPattern) =>
        string.Format(
            System.Globalization.CultureInfo.InvariantCulture,
            "-hide_banner -v error -i {0} -vf fps={1},scale={2}:{2}:force_original_aspect_ratio=decrease -vsync 0 -q:v 3 {3}",
            Quote(inputPath), fps, maxPixel, Quote(outputPattern));

    public static string BuildGrayArgs(string inputPath, double fps) =>
        string.Format(
            System.Globalization.CultureInfo.InvariantCulture,
            "-hide_banner -v error -i {0} -vf fps={1},scale=8:8,format=gray -f rawvideo -pix_fmt gray pipe:1",
            Quote(inputPath), fps);

    private static string Quote(string path) => "\"" + path.Replace("\"", string.Empty) + "\"";

    // MARK: Operations

    /// <summary>Duration from the file itself. Ports MediaInfo.duration (MediaExtractors.swift:160).</summary>
    public static double? MediaDuration(string path, FFmpegPaths paths)
    {
        return ProbeDurationAsync(path, paths).GetAwaiter().GetResult();
    }

    public static async System.Threading.Tasks.Task<double?> ProbeDurationAsync(
        string path, FFmpegPaths paths, System.Threading.CancellationToken ct = default)
    {
        paths.Validate();
        var (exit, stdout, _) = await RunCapturingAsync(paths.FFprobeExe, BuildProbeArgs(path), ct);
        if (exit != 0)
        {
            return null;
        }

        if (double.TryParse(
                stdout.Trim(),
                System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture,
                out double seconds)
            && System.Double.IsFinite(seconds) && seconds > 0)
        {
            return seconds;
        }

        return null;
    }

    public static async System.Threading.Tasks.Task<bool> HasStreamAsync(
        string path, char stream, FFmpegPaths paths, System.Threading.CancellationToken ct = default)
    {
        paths.Validate();
        var (exit, stdout, _) = await RunCapturingAsync(paths.FFprobeExe, BuildStreamCheckArgs(path, stream), ct);
        return exit == 0 && stdout.Trim().Length > 0;
    }

    /// <summary>
    /// Decodes to 16 kHz mono and writes window-second WAV pieces hop seconds
    /// apart, skipping silent ones; streams so memory stays at one window.
    /// Ports AudioExtractor.windows (MediaExtractors.swift:34). One model
    /// input ignores anything past 30 s, so windows stay ≤ 30 s.
    /// </summary>
    public static async System.Threading.Tasks.Task<(System.Collections.Generic.IReadOnlyList<MediaPiece> Pieces, double Duration)>
        DecodeAudioWindowsAsync(
            string path, double window, double hop, double minimumSeconds, string folder,
            FFmpegPaths paths, System.Threading.CancellationToken ct = default)
    {
        paths.Validate();
        System.IO.Directory.CreateDirectory(folder);
        double? probed = await ProbeDurationAsync(path, paths, ct);

        int windowSamples = (int)(window * SampleRate);
        int hopSamples = (int)(hop * SampleRate);
        var buffer = new System.Collections.Generic.List<short>();
        int offset = 0;
        var pieces = new System.Collections.Generic.List<MediaPiece>();

        using (var process = new System.Diagnostics.Process { StartInfo = StartInfo(paths.FFmpegExe, BuildPcmArgs(path)) })
        {
            process.Start();
            var stderrTask = process.StandardError.ReadToEndAsync();
            var stdout = process.StandardOutput.BaseStream;
            byte[] chunk = new byte[64 * 1024];
            byte? pending = null;
            int read;
            while ((read = await stdout.ReadAsync(chunk, 0, chunk.Length, ct)) > 0)
            {
                int i = 0;
                if (pending.HasValue && read > 0)
                {
                    buffer.Add((short)(pending.Value | (chunk[0] << 8)));
                    i = 1;
                    pending = null;
                }

                int pairs = (read - i) / 2;
                for (int k = 0; k < pairs; k++)
                {
                    buffer.Add((short)(chunk[i + 2 * k] | (chunk[i + 2 * k + 1] << 8)));
                }

                if ((read - i) % 2 == 1)
                {
                    pending = chunk[read - 1];
                }

                while (buffer.Count >= windowSamples)
                {
                    EmitWindow(buffer, 0, windowSamples, offset, folder, pieces);
                    buffer.RemoveRange(0, hopSamples);
                    offset += hopSamples;
                }
            }

            await process.WaitForExitAsync(ct);
            string stderr = await stderrTask;
            if (process.ExitCode != 0 && pieces.Count == 0 && buffer.Count == 0)
            {
                throw ExtractError.Unreadable("audio decoding failed: " + Tail(stderr));
            }
        }

        // The tail: new audio beyond the previous window's overlap, or the
        // whole file if shorter than a window. (MediaExtractors.swift:75)
        int alreadyCovered = offset == 0 ? 0 : windowSamples - hopSamples;
        if (buffer.Count - alreadyCovered >= (int)(minimumSeconds * SampleRate))
        {
            EmitWindow(buffer, 0, buffer.Count, offset, folder, pieces);
        }

        double duration = probed ?? ((offset + buffer.Count) / SampleRate);
        return (pieces, duration);
    }

    private static void EmitWindow(
        System.Collections.Generic.List<short> buffer, int from, int count, int offset,
        string folder, System.Collections.Generic.List<MediaPiece> pieces)
    {
        short[] array = buffer.ToArray();
        if (Rms(array, from, count) <= SilenceRmsThreshold)
        {
            return;
        }

        string outPath = System.IO.Path.Combine(folder, System.Guid.NewGuid().ToString("N") + ".wav");
        WriteWav(outPath, array, from, count);
        pieces.Add(new MediaPiece(outPath, offset / SampleRate, (offset + count) / SampleRate));
    }

    /// <summary>
    /// Samples a frame every interval seconds, keeps one per shot. Ports
    /// VideoExtractor.keyframes (MediaExtractors.swift:105): step is at least
    /// the interval (max one frame per 3 s by default) and tightened to fit
    /// MaxFrames; near-duplicate hashes (≤4 bits) only extend the shot.
    /// </summary>
    public static async System.Threading.Tasks.Task<(
        System.Collections.Generic.IReadOnlyList<MediaPiece> Frames, double Duration, bool HasAudio)>
        ExtractKeyframesAsync(
            string path, double interval, int maxPixel, int maxFrames, string folder,
            FFmpegPaths paths, System.Threading.CancellationToken ct = default)
    {
        paths.Validate();
        System.IO.Directory.CreateDirectory(folder);
        double duration = await ProbeDurationAsync(path, paths, ct) ?? 0;
        bool hasAudio = await HasStreamAsync(path, 'a', paths, ct);
        bool hasVideo = await HasStreamAsync(path, 'v', paths, ct);
        if (!(duration > 0) || !hasVideo)
        {
            return (System.Array.Empty<MediaPiece>(), duration, hasAudio);
        }

        double step = ComputeStep(duration, interval, maxFrames);
        var times = CandidateTimes(duration, step);
        if (times.Count == 0)
        {
            return (System.Array.Empty<MediaPiece>(), duration, hasAudio);
        }

        double fps = 1.0 / step;
        var hashes = await RunGrayHashesAsync(path, fps, paths, ct);
        if (hashes.Count != times.Count)
        {
            // Frame selection diverged; pair up what lines up.
            int n = System.Math.Min(hashes.Count, times.Count);
            times = new System.Collections.Generic.List<double>(times).GetRange(0, n);
            hashes = hashes.GetRange(0, n);
        }

        string pattern = System.IO.Path.Combine(folder, "cand%06d.jpg");
        await RunToFolderAsync(paths.FFmpegExe, BuildCandidatesArgs(path, fps, maxPixel, pattern), ct);

        var files = new System.Collections.Generic.List<string>(
            System.IO.Directory.GetFiles(folder, "cand*.jpg"));
        files.Sort(System.StringComparer.Ordinal);

        var frames = new System.Collections.Generic.List<MediaPiece>();
        var keptIndexes = new System.Collections.Generic.HashSet<int>();
        foreach (var (index, start, end) in DedupeShots(times, hashes, duration))
        {
            keptIndexes.Add(index);
            if (index < files.Count)
            {
                frames.Add(new MediaPiece(files[index], start, end));
            }
        }

        for (int i = 0; i < files.Count; i++)
        {
            if (!keptIndexes.Contains(i))
            {
                try
                {
                    System.IO.File.Delete(files[i]);
                }
                catch
                {
                    // Scratch cleanup must never fail a run.
                }
            }
        }

        return (frames, duration, hasAudio);
    }

    private static async System.Threading.Tasks.Task<System.Collections.Generic.List<ulong>> RunGrayHashesAsync(
        string path, double fps, FFmpegPaths paths, System.Threading.CancellationToken ct)
    {
        byte[] raw = await RunCapturingBytesAsync(paths.FFmpegExe, BuildGrayArgs(path, fps), ct);
        var hashes = new System.Collections.Generic.List<ulong>();
        byte[] frame = new byte[64];
        for (int i = 0; i + 64 <= raw.Length; i += 64)
        {
            System.Buffer.BlockCopy(raw, i, frame, 0, 64);
            hashes.Add(AverageHash(frame));
        }

        return hashes;
    }

    // MARK: Process plumbing (exe paths always come from FFmpegPaths)

    private static System.Diagnostics.ProcessStartInfo StartInfo(string exe, string args)
    {
        return new System.Diagnostics.ProcessStartInfo
        {
            FileName = exe,
            Arguments = args,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
    }

    private static async System.Threading.Tasks.Task<(int Exit, string Stdout, string Stderr)> RunCapturingAsync(
        string exe, string args, System.Threading.CancellationToken ct)
    {
        using var process = new System.Diagnostics.Process { StartInfo = StartInfo(exe, args) };
        process.Start();
        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync(ct);
        return (process.ExitCode, await stdoutTask, await stderrTask);
    }

    private static async System.Threading.Tasks.Task<byte[]> RunCapturingBytesAsync(
        string exe, string args, System.Threading.CancellationToken ct)
    {
        using var process = new System.Diagnostics.Process { StartInfo = StartInfo(exe, args) };
        process.Start();
        var stderrTask = process.StandardError.ReadToEndAsync();
        using var memory = new System.IO.MemoryStream();
        await process.StandardOutput.BaseStream.CopyToAsync(memory, ct);
        await process.WaitForExitAsync(ct);
        string stderr = await stderrTask;
        if (process.ExitCode != 0)
        {
            throw ExtractError.Unreadable("ffmpeg failed: " + Tail(stderr));
        }

        return memory.ToArray();
    }

    private static async System.Threading.Tasks.Task RunToFolderAsync(
        string exe, string args, System.Threading.CancellationToken ct)
    {
        var (exit, _, stderr) = await RunCapturingAsync(exe, args, ct);
        if (exit != 0)
        {
            throw ExtractError.Unreadable("ffmpeg failed: " + Tail(stderr));
        }
    }

    private static string Tail(string stderr, int max = 300)
    {
        string tail = stderr.Trim();
        return tail.Length > max ? tail.Substring(tail.Length - max) : tail;
    }
}
