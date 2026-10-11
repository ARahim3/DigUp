// digup-embed.exe: EmbeddingGemma 2 on llama.cpp as a process.
// JSON-lines protocol of worker/digup_worker.py and Sources/digup/WorkerService.swift:
// one request object per stdin line, one reply object per stdout line. Logs go to stderr.
// The first line printed is {"ready": ...} once loading was tried.
//
//   {"id": 1, "op": "info"}
//   {"id": 2, "op": "text",  "inputs": ["...", ...]}
//   {"id": 3, "op": "image", "inputs": ["C:\\a.jpg", ...], "budget": 280}
//   {"id": 4, "op": "audio", "inputs": ["C:\\a.wav", ...]}
//   {"id": 5, "op": "quit"}
//
// Reply: {"id": 2, "ok": true, "dim": 768, "count": N,
//         "vectors": "<base64 float32 LE, N x dim>", "errors": [...]}.
// A failed item gets a zero vector and a message in "errors";
// a failed request gets {"ok": false, "error": "..."}.
// Needs llama.dll + mtmd.dll (+ ggml*.dll) next to this exe:
// build them with windows\scripts\build-llama-windows.ps1.

using System.Text.Json;
using DigUp.Embed;

internal static class Program
{
    // Which vectors this pipeline makes. Mirrors LlamaEmbedder.vectorVersion:
    // change it only when the vectors change, then every index embeds again.
    private const int VectorVersion = 1;
    private const int Dim = 768;
    private const string BuildTag = "b11461";
    private const string Model = "google/embeddinggemma-2";
    private const string Revision = "bfcd298762cc34d0357ece5ebdd31791a3a374d8";
    private const string Dtype = "text-q8_0+mmproj-q8_0";
    private const string TextFile = "embeddinggemma-2-Q8_0.gguf";
    private const string MediaFile = "mmproj-embeddinggemma-2-Q8_0.gguf";
    private static readonly int[] Budgets = [70, 140, 280, 560, 1120];

    private static Embedder? _embedder;
    private static bool _textOnly;

    private static int Main(string[] args)
    {
        _textOnly = args.Contains("--text-only");

        if (!FindModelFiles(out string? textPath, out string? mediaPath) || textPath is null)
        {
            Emit(new Dictionary<string, object?> { ["ready"] = false, ["error"] = MissingModelsMessage() });
            return 1;
        }
        if (!_textOnly && mediaPath is null)
        {
            Emit(new Dictionary<string, object?> { ["ready"] = false, ["error"] = $"{MediaFile} (images and audio) isn't downloaded yet" });
            return 1;
        }

        try
        {
            _embedder = new Embedder(textPath, mediaPath, _textOnly);
        }
        catch (DllNotFoundException ex)
        {
            Emit(new Dictionary<string, object?> { ["ready"] = false, ["error"] = NativeError(ex) });
            return 1;
        }
        catch (BadImageFormatException)
        {
            Emit(new Dictionary<string, object?> { ["ready"] = false,
                ["error"] = "llama.dll or mtmd.dll has the wrong CPU type: use windows\\native\\x64 on Intel/AMD and windows\\native\\arm64 on Snapdragon." });
            return 1;
        }
        catch (Exception ex)
        {
            Emit(new Dictionary<string, object?> { ["ready"] = false, ["error"] = Chop(ex.Message, 500) });
            return 1;
        }

        var e = _embedder;
        Log($"ready in {e.LoadSeconds} s ({(_textOnly ? "text-only" : "full")}, llama.cpp {BuildTag}, vectors {VectorVersion})");
        Emit(new Dictionary<string, object?> { ["ready"] = true, ["info"] = Info(e) });

        string? line;
        while ((line = Console.ReadLine()) is not null)
        {
            // Be liberal in what we take: strip a BOM and edge space, so a
            // client that writes UTF-8 with a preamble still parses.
            line = line.Trim().TrimStart('﻿');
            if (line.Length == 0) continue;
            JsonDocument doc;
            try { doc = JsonDocument.Parse(line); }
            catch { continue; } // a bad line is skipped, like WorkerService.swift
            using (doc)
            {
                var req = doc.RootElement;
                string id = req.TryGetProperty("id", out var idProp) ? idProp.GetRawText() : "null";
                string? op = req.TryGetProperty("op", out var opProp) ? opProp.GetString() : null;
                string[] inputs = req.TryGetProperty("inputs", out var inProp) && inProp.ValueKind == JsonValueKind.Array
                    ? inProp.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String)
                        .Select(x => x.GetString()!).ToArray()
                    : [];
                try
                {
                    switch (op)
                    {
                        case "quit":
                            Emit(new Dictionary<string, object?> { ["id"] = IdOf(id), ["ok"] = true });
                            _embedder.Dispose();
                            return 0;
                        case "info":
                            Emit(new Dictionary<string, object?> { ["id"] = IdOf(id), ["ok"] = true, ["info"] = Info(e) });
                            break;
                        case "text":
                            ReplyVectors(id, e.EmbedTexts(inputs).Select(v => ((float[]?)v, (string?)null)).ToArray());
                            break;
                        case "image":
                            int budget = req.TryGetProperty("budget", out var bProp) && bProp.TryGetInt32(out var b)
                                ? b : 280;
                            if (!Budgets.Contains(budget))
                                throw new InvalidOperationException($"budget must be one of {string.Join(",", Budgets)}");
                            ReplyVectors(id, inputs.Select(p => e.EmbedImageFile(p, budget)).ToArray());
                            break;
                        case "audio":
                            // Prepared WAVs are always 16 kHz mono (see AudioVideoExtractor).
                            ReplyVectors(id, inputs.Select(p => e.EmbedAudioFile(p, 16000)).ToArray());
                            break;
                        default:
                            throw new InvalidOperationException($"unknown op {op ?? "(none)"}");
                    }
                }
                catch (Exception ex)
                {
                    Emit(new Dictionary<string, object?>
                        { ["id"] = IdOf(id), ["ok"] = false, ["error"] = Chop(ex.Message, 500) });
                }
            }
        }
        _embedder.Dispose();
        return 0;
    }

    // One vector per input, or null plus why it has none (a bad file must not
    // sink its neighbours). Nulls become zero vectors in the reply.
    private static void ReplyVectors(string id, (float[]? Vector, string? Error)[] items)
    {
        var flat = new float[items.Length * Dim];
        var errors = new List<object?>(items.Length);
        for (int i = 0; i < items.Length; i++)
        {
            if (items[i].Vector is not null)
            {
                if (items[i].Vector!.Length != Dim) { errors.Add($"bad vector ({items[i].Vector!.Length}, want {Dim})"); continue; }
                Array.Copy(items[i].Vector!, 0, flat, i * Dim, Dim);
            }
            errors.Add(items[i].Error is null ? null : (object)items[i].Error!);
        }
        var bytes = new byte[flat.Length * sizeof(float)];
        Buffer.BlockCopy(flat, 0, bytes, 0, bytes.Length);
        Emit(new Dictionary<string, object?>
        {
            ["id"] = IdOf(id),
            ["ok"] = true,
            ["dim"] = Dim,
            ["count"] = items.Length,
            ["vectors"] = Convert.ToBase64String(bytes),
            ["errors"] = errors,
        });
    }

    private static Dictionary<string, object?> Info(Embedder e) => new()
    {
        ["model"] = Model,
        ["revision"] = Revision,
        ["runtime"] = $"llama.cpp-vectors{VectorVersion}",
        ["dtype"] = Dtype,
        ["dim"] = Dim,
        ["text_only"] = _textOnly,
        ["load_seconds"] = e.LoadSeconds,
    };

    private static string NativeError(DllNotFoundException ex) =>
        "llama.dll or mtmd.dll was not found (tried next to digup-embed.exe and on PATH)."
        + " Build them with: powershell -File windows\\scripts\\build-llama-windows.ps1"
        + $" ({ex.Message})";

    // $DIGUP_MODELS wins when set; else %LocalAppData%\DigUp\Models, then the
    // Hugging Face cache. Only the text file is needed for --text-only.
    private static bool FindModelFiles(out string? text, out string? media)
    {
        text = media = null;
        var dirs = new List<string>();
        string? chosen = Environment.GetEnvironmentVariable("DIGUP_MODELS");
        if (!string.IsNullOrEmpty(chosen)) dirs.Add(chosen);
        else
        {
            dirs.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DigUp", "Models"));
            dirs.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".cache", "huggingface"));
        }
        foreach (string d in dirs)
        {
            try
            {
                string t = Path.Combine(d, TextFile);
                if (File.Exists(t))
                {
                    text = t;
                    string m = Path.Combine(d, MediaFile);
                    if (File.Exists(m)) media = m;
                    return true;
                }
            }
            catch { }
        }
        return false;
    }

    private static string MissingModelsMessage()
    {
        var local = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DigUp", "Models");
        return $"no model file ({TextFile}) in {local}."
            + " Set DIGUP_MODELS to the folder with the EmbeddingGemma 2 files, or put them there.";
    }

    private static void Emit(Dictionary<string, object?> reply)
    {
        Console.WriteLine(JsonSerializer.Serialize(reply));
        Console.Out.Flush();
    }

    // The reply keeps the request id's own JSON shape (number or string).
    private static object IdOf(string raw)
    {
        try { return JsonDocument.Parse(raw).RootElement.Clone(); }
        catch { return raw; }
    }
    private static void Log(string message) => Console.Error.WriteLine($"[digup-embed] {message}");
    private static string Chop(string text, int max) => text.Length <= max ? text : text[..max];
}
