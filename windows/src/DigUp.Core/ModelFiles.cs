using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;

namespace DigUp.Core;

/// <summary>One model file: its Hugging Face address at the pinned revision,
/// its size, and its SHA-256.</summary>
public sealed record ModelFile(string Name, long Bytes, string Sha256)
{
    /// <summary>Hugging Face's address for this file at the pinned revision
    /// (it redirects to a CDN that takes HTTP ranges).</summary>
    public string Url =>
        $"https://huggingface.co/{ModelFiles.Repository}/resolve/{ModelFiles.Revision}/{Name}";
}

/// <summary>The EmbeddingGemma 2 files the app runs: ggml-org's Q8_0 GGUF conversion at
/// one pinned revision. Ports ModelFiles.swift.</summary>
public static class ModelFiles
{
    public const string Repository = "ggml-org/embeddinggemma-2-GGUF";
    public const string Revision = "bfcd298762cc34d0357ece5ebdd31791a3a374d8";

    /// <summary>The text model (310 MB): all that queries need.</summary>
    public static readonly ModelFile Text = new(
        "embeddinggemma-2-Q8_0.gguf", 309_855_456,
        "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135");

    /// <summary>The image and audio encoders (555 MB).</summary>
    public static readonly ModelFile Media = new(
        "mmproj-embeddinggemma-2-Q8_0.gguf", 554_821_024,
        "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f");

    /// <summary>In download order.</summary>
    public static readonly ModelFile[] All = { Text, Media };

    public static long TotalBytes => Text.Bytes + Media.Bytes;

    /// <summary>Where the app keeps them: %LocalAppData%\DigUp\Models.</summary>
    public static string InstalledDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DigUp", "Models");

    /// <summary>The pinned revision's folder in the Hugging Face cache ($HF_HUB_CACHE,
    /// $HF_HOME/hub, or ~/.cache/huggingface/hub).</summary>
    public static string SnapshotDirectory()
    {
        string? hub = Environment.GetEnvironmentVariable("HF_HUB_CACHE");
        if (hub is null)
        {
            string? home = Environment.GetEnvironmentVariable("HF_HOME");
            hub = home is null
                ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    ".cache", "huggingface", "hub")
                : Path.Combine(home, "hub");
        }
        return Path.Combine(hub,
            "models--" + Repository.Replace('/', '-'), "snapshots", Revision);
    }

    /// <summary><paramref name="file"/> in the Hugging Face cache, when it's there at
    /// the right size (its checksum is for the caller to check).</summary>
    public static string? CachedCopy(ModelFile file)
    {
        string path = Path.Combine(SnapshotDirectory(), file.Name);
        try
        {
            return new FileInfo(path).Length == file.Bytes ? path : null;
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    /// <summary>The files that aren't in <paramref name="folder"/> yet. Only verified
    /// files get their final name, so being there is enough.</summary>
    public static List<ModelFile> Missing(string folder)
    {
        var missing = new List<ModelFile>();
        foreach (var file in All)
        {
            if (!File.Exists(Path.Combine(folder, file.Name)))
                missing.Add(file);
        }
        return missing;
    }

    /// <summary>The SHA-256 of a file as lowercase hex, read in 8 MB pieces
    /// (a 555 MB file takes about half a second).</summary>
    public static string Sha256Of(string path)
    {
        using var sha = SHA256.Create();
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
            bufferSize: 1 << 20, useAsync: false);
        var buffer = new byte[8 << 20];
        int read;
        while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
            sha.TransformBlock(buffer, 0, read, null, 0);
        sha.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
        return Convert.ToHexString(sha.Hash ?? Array.Empty<byte>()).ToLowerInvariant();
    }

    /// <summary>Downloads <paramref name="file"/> into <paramref name="folder"/>,
    /// resuming a previous partial download (HTTP range over a ".part" file), then
    /// verifies size and SHA-256 before moving it into place. Throws on mismatch.</summary>
    public static async Task DownloadAsync(
        ModelFile file,
        string folder,
        IProgress<double>? progress = null,
        CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(folder);
        string dest = Path.Combine(folder, file.Name);
        if (File.Exists(dest))
        {
            progress?.Report(1);
            return;
        }

        string part = dest + ".part";
        long have = 0;
        if (File.Exists(part))
        {
            have = new FileInfo(part).Length;
            if (have > file.Bytes)
            {
                File.Delete(part);
                have = 0;
            }
        }

        using var client = new HttpClient();
        client.DefaultRequestHeaders.UserAgent.ParseAdd("DigUp/1.0");
        using var request = new HttpRequestMessage(HttpMethod.Get, file.Url);
        if (have > 0)
            request.Headers.Range = new RangeHeaderValue(have, null);
        using var response = await client
            .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
            .ConfigureAwait(false);
        response.EnsureSuccessStatusCode();

        bool resumed = have > 0 && response.StatusCode == HttpStatusCode.PartialContent;
        if (!resumed)
            have = 0;
        using var network = await response.Content
            .ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var output = new FileStream(part, resumed ? FileMode.Append : FileMode.Create,
            FileAccess.Write, FileShare.None, 1 << 17, useAsync: true);

        var buffer = new byte[1 << 17];
        int read;
        while ((read = await network.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
        {
            await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
            have += read;
            progress?.Report((double)have / file.Bytes);
        }
        await output.FlushAsync(cancellationToken).ConfigureAwait(false);
        output.Close();

        if (new FileInfo(part).Length != file.Bytes)
            throw new InvalidDataException(
                $"{file.Name}: expected {file.Bytes} bytes, got {new FileInfo(part).Length}");
        if (!Sha256Of(part).Equals(file.Sha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException($"{file.Name}: SHA-256 mismatch");
        File.Move(part, dest, overwrite: false);
        progress?.Report(1);
    }
}
