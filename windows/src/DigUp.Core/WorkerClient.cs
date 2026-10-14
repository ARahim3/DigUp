// Embedding worker client: JSON-lines protocol over a child process's
// stdin/stdout. Ports WorkerInfo / Embedder / WorkerConfig / WorkerError /
// EmbeddingWorker (Worker.swift) against the protocol in worker/digup_worker.py.
//
// Protocol (one JSON object per line each way; logs go to the child's stderr):
//   -> {"id":1,"op":"info"}
//   -> {"id":2,"op":"text","inputs":["task: search result | query: cat", ...]}
//   -> {"id":3,"op":"image","inputs":["/tmp/a.jpg", ...],"budget":280}
//   -> {"id":4,"op":"audio","inputs":["/tmp/a.wav", ...]}
//   -> {"id":5,"op":"quit"}
//   <- {"ready":true,"info":{...}}                       (once, after model load)
//   <- {"id":2,"ok":true,"dim":768,"count":N,
//       "vectors":"<base64 float32 LE, N x dim>","errors":[null,...]}
// A failed item gets a null vector and a message in "errors"; a failed
// request gets {"ok":false,"error":"..."}. Budgets: 70/140/280/560/1120.
// Text inputs arrive already prompted; prompts are the caller's business.
//
// The worker executable path is injected via WorkerConfig; there is no
// default and no hard-coded tool location.

namespace DigUp.Core;

/// <summary>What the embedding runtime reports about its model; part of the index fingerprint.</summary>
public sealed record WorkerInfo(
    string Model,
    string Revision,
    string Runtime,
    string Dtype,
    int Dim,
    bool TextOnly,
    double? LoadSeconds)
{
    /// <summary>Vectors from different sources must never share an index. (Worker.swift:25)</summary>
    public string VectorSource => $"{Model}@{ShortRevision} {Runtime} {Dtype}";

    private string ShortRevision => Revision.Length > 7 ? Revision.Substring(0, 7) : Revision;
}

/// <summary>One embedding (or why the item could not be embedded).</summary>
public sealed record Embedding(float[]? Vector, string? Error);

/// <summary>How to start a worker process. Executable and arguments are injected.</summary>
public sealed record WorkerConfig(
    string Executable,
    System.Collections.Generic.IReadOnlyList<string> Arguments,
    System.Collections.Generic.Dictionary<string, string>? Environment = null,
    string? LogPath = null,
    bool TextOnly = false);

public sealed class WorkerError : System.Exception
{
    public enum Kind
    {
        NotFound,
        Failed,
        Died,
    }

    public Kind Failure { get; }

    private WorkerError(Kind kind, string message)
        : base(message)
    {
        Failure = kind;
    }

    public static WorkerError NotFound(string why) => new(Kind.NotFound, $"worker not found: {why}");

    public static WorkerError Failed(string why) => new(Kind.Failed, $"worker error: {why}");

    public static WorkerError Died(string why) => new(Kind.Died, $"worker stopped: {why}");
}

/// <summary>
/// The calls every embedding runtime answers. One thread at a time.
/// Ports Embedder (Worker.swift:31).
/// </summary>
public interface IEmbedder : System.IDisposable
{
    WorkerInfo Info { get; }
    float[][] EmbedTexts(System.Collections.Generic.IReadOnlyList<string> texts);
    Embedding[] EmbedImages(System.Collections.Generic.IReadOnlyList<string> paths, int budget);
    Embedding[] EmbedAudio(System.Collections.Generic.IReadOnlyList<string> paths);
    void Close();
}

/// <summary>
/// Talks to a worker process over stdin/stdout, one JSON line each way.
/// The model lives in that separate process so its memory goes back to the
/// OS when it exits. Ports EmbeddingWorker (Worker.swift:108).
/// </summary>
public sealed class WorkerClient : IEmbedder
{
    private readonly System.Diagnostics.Process _process;
    private readonly object _gate = new();
    private readonly string? _logPath;
    private int _nextId = 1;
    private bool _closed;

    private sealed class Request
    {
        [System.Text.Json.Serialization.JsonPropertyName("id")]
        public int Id { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("op")]
        public string Op { get; set; } = string.Empty;

        [System.Text.Json.Serialization.JsonPropertyName("inputs")]
        [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
        public System.Collections.Generic.IReadOnlyList<string>? Inputs { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("budget")]
        [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
        public int? Budget { get; set; }
    }

    private sealed class ReplyInfo
    {
        [System.Text.Json.Serialization.JsonPropertyName("model")]
        public string Model { get; set; } = string.Empty;

        [System.Text.Json.Serialization.JsonPropertyName("revision")]
        public string Revision { get; set; } = string.Empty;

        [System.Text.Json.Serialization.JsonPropertyName("runtime")]
        public string Runtime { get; set; } = string.Empty;

        [System.Text.Json.Serialization.JsonPropertyName("dtype")]
        public string Dtype { get; set; } = string.Empty;

        [System.Text.Json.Serialization.JsonPropertyName("dim")]
        public int Dim { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("text_only")]
        public bool TextOnly { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("load_seconds")]
        public double? LoadSeconds { get; set; }
    }

    private sealed class Reply
    {
        [System.Text.Json.Serialization.JsonPropertyName("id")]
        public int? Id { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("ok")]
        public bool? Ok { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("ready")]
        public bool? Ready { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("error")]
        public string? Error { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("dim")]
        public int? Dim { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("count")]
        public int? Count { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("vectors")]
        public string? Vectors { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("errors")]
        public string?[]? Errors { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("info")]
        public ReplyInfo? Info { get; set; }
    }

    private static readonly System.Text.Json.JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
    };

    public WorkerInfo Info { get; private set; } = new(string.Empty, string.Empty, string.Empty, string.Empty, 0, false, null);

    public WorkerClient(WorkerConfig config)
    {
        if (string.IsNullOrWhiteSpace(config.Executable))
        {
            throw WorkerError.NotFound("worker executable path was not injected");
        }

        if (!System.IO.File.Exists(config.Executable))
        {
            throw WorkerError.NotFound($"not executable: {config.Executable}");
        }

        _logPath = config.LogPath;
        var start = new System.Diagnostics.ProcessStartInfo
        {
            FileName = config.Executable,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            // With a log path the worker's chatter (model load notes) goes to
            // the file, async-drained so a full pipe can never block it.
            // Without one it inherits our console (dev runs stay visible).
            RedirectStandardError = !string.IsNullOrEmpty(config.LogPath),
            CreateNoWindow = true,
            // No preamble: Encoding.UTF8 starts the stream with a BOM that a
            // line reader on the other end would choke on.
            StandardInputEncoding = new System.Text.UTF8Encoding(false),
            StandardOutputEncoding = System.Text.Encoding.UTF8,
        };
        foreach (string arg in config.Arguments)
        {
            start.ArgumentList.Add(arg);
        }

        if (config.TextOnly)
        {
            start.ArgumentList.Add("--text-only");
        }

        if (config.Environment != null)
        {
            foreach (var (key, value) in config.Environment)
            {
                start.Environment[key] = value;
            }
        }

        _process = new System.Diagnostics.Process { StartInfo = start };
        try
        {
            if (!_process.Start())
            {
                throw WorkerError.NotFound($"could not start: {config.Executable}");
            }
        }
        catch (System.Exception error) when (error is not WorkerError)
        {
            throw WorkerError.NotFound($"{config.Executable}: {error.Message}");
        }

        if (!string.IsNullOrEmpty(config.LogPath))
        {
            try
            {
                string? dir = System.IO.Path.GetDirectoryName(config.LogPath);
                if (!string.IsNullOrEmpty(dir)) System.IO.Directory.CreateDirectory(dir);
                string capture = config.LogPath;
                _process.ErrorDataReceived += (_, e) =>
                {
                    if (e.Data is null) return;
                    try { System.IO.File.AppendAllText(capture, e.Data + "\n"); } catch { }
                };
                _process.BeginErrorReadLine();
            }
            catch
            {
                // Logging must never stop the worker.
            }
        }

        var ready = ReadReply();
        if (ready.Ready != true || ready.Info == null)
        {
            Close();
            throw WorkerError.Failed(ready.Error ?? "didn't start" + LogTail());
        }

        Info = ToInfo(ready.Info);
    }

    public float[][] EmbedTexts(System.Collections.Generic.IReadOnlyList<string> texts)
    {
        if (texts.Count == 0)
        {
            return System.Array.Empty<float[]>();
        }

        var embeddings = Send("text", texts, budget: null);
        var rows = new float[texts.Count][];
        for (int i = 0; i < texts.Count; i++)
        {
            rows[i] = embeddings[i].Vector ?? System.Array.Empty<float>();
        }

        return rows;
    }

    public Embedding[] EmbedImages(System.Collections.Generic.IReadOnlyList<string> paths, int budget)
    {
        if (paths.Count == 0)
        {
            return System.Array.Empty<Embedding>();
        }

        return Send("image", paths, budget);
    }

    public Embedding[] EmbedAudio(System.Collections.Generic.IReadOnlyList<string> paths)
    {
        if (paths.Count == 0)
        {
            return System.Array.Empty<Embedding>();
        }

        return Send("audio", paths, budget: null);
    }

    /// <summary>Asks the worker for its model info (the "info" op).</summary>
    public WorkerInfo RefreshInfo()
    {
        lock (_gate)
        {
            var reply = RoundTrip(new Request { Id = NextId(), Op = "info" });
            if (reply.Ok == true && reply.Info != null)
            {
                Info = ToInfo(reply.Info);
                return Info;
            }

            throw WorkerError.Failed(reply.Error ?? "no info");
        }
    }

    /// <summary>Frees the model. Safe to call twice.</summary>
    public void Close()
    {
        lock (_gate)
        {
            if (_closed)
            {
                return;
            }

            _closed = true;
            try
            {
                if (!_process.HasExited)
                {
                    string quit = System.Text.Json.JsonSerializer.Serialize(
                        new Request { Id = 0, Op = "quit" }, JsonOptions) + "\n";
                    try
                    {
                        _process.StandardInput.Write(quit);
                        _process.StandardInput.Flush();
                    }
                    catch
                    {
                        // The worker may already be gone.
                    }

                    try
                    {
                        _process.StandardInput.Close();
                    }
                    catch
                    {
                    }

                    var deadline = System.DateTime.UtcNow.AddSeconds(3);
                    while (!_process.HasExited && System.DateTime.UtcNow < deadline)
                    {
                        System.Threading.Thread.Sleep(20);
                    }

                    if (!_process.HasExited)
                    {
                        _process.Kill();
                    }
                }
            }
            catch
            {
                // Close must not throw.
            }
        }
    }

    public void Dispose()
    {
        Close();
        _process.Dispose();
    }

    private int NextId() => _nextId++;

    private Embedding[] Send(string op, System.Collections.Generic.IReadOnlyList<string> inputs, int? budget)
    {
        lock (_gate)
        {
            if (_closed)
            {
                throw WorkerError.Died("client is closed");
            }

            int id = NextId();
            Reply reply;
            try
            {
                reply = RoundTrip(new Request { Id = id, Op = op, Inputs = inputs, Budget = budget });
            }
            catch (System.IO.IOException error)
            {
                throw WorkerError.Died($"can't write to the worker: {error.Message}{LogTail()}");
            }

            if (reply.Id != id)
            {
                throw WorkerError.Failed("reply out of order");
            }

            if (reply.Ok != true || string.IsNullOrEmpty(reply.Vectors))
            {
                throw WorkerError.Failed(reply.Error ?? "no vectors");
            }

            byte[] data;
            try
            {
                data = System.Convert.FromBase64String(reply.Vectors);
            }
            catch
            {
                throw WorkerError.Failed("vectors are not base64");
            }

            int dim = reply.Dim ?? Info.Dim;
            float[] floats = LittleEndianFloats(data);
            if (floats.Length != dim * inputs.Count)
            {
                throw WorkerError.Failed($"got {floats.Length} floats for {inputs.Count} inputs of dim {dim}");
            }

            string?[] errors = reply.Errors ?? System.Array.Empty<string?>();
            var result = new Embedding[inputs.Count];
            for (int i = 0; i < inputs.Count; i++)
            {
                string? error = i < errors.Length ? errors[i] : null;
                float[]? vector = null;
                if (error == null)
                {
                    vector = new float[dim];
                    System.Array.Copy(floats, i * dim, vector, 0, dim);
                }

                result[i] = new Embedding(vector, error);
            }

            return result;
        }
    }

    private Reply RoundTrip(Request request)
    {
        string line = System.Text.Json.JsonSerializer.Serialize(request, JsonOptions) + "\n";
        _process.StandardInput.Write(line);
        _process.StandardInput.Flush();
        return ReadReply();
    }

    private Reply ReadReply()
    {
        while (true)
        {
            string? line = _process.StandardOutput.ReadLine();
            if (line == null)
            {
                throw WorkerError.Died("exited" + LogTail());
            }

            if (line.Trim().Length == 0)
            {
                continue;
            }

            var reply = System.Text.Json.JsonSerializer.Deserialize<Reply>(line, JsonOptions);
            if (reply == null)
            {
                throw WorkerError.Failed("unreadable reply");
            }

            return reply;
        }
    }

    private static WorkerInfo ToInfo(ReplyInfo info) =>
        new(info.Model, info.Revision, info.Runtime, info.Dtype, info.Dim, info.TextOnly, info.LoadSeconds);

    internal static float[] LittleEndianFloats(byte[] data)
    {
        if (data.Length % 4 != 0)
        {
            throw WorkerError.Failed($"got {data.Length} bytes, not f32");
        }

        float[] floats = new float[data.Length / 4];
        if (System.BitConverter.IsLittleEndian)
        {
            System.Buffer.BlockCopy(data, 0, floats, 0, data.Length);
        }
        else
        {
            byte[] word = new byte[4];
            for (int i = 0; i < floats.Length; i++)
            {
                word[0] = data[4 * i + 3];
                word[1] = data[4 * i + 2];
                word[2] = data[4 * i + 1];
                word[3] = data[4 * i + 0];
                floats[i] = System.BitConverter.ToSingle(word, 0);
            }
        }

        return floats;
    }

    private string LogTail()
    {
        if (string.IsNullOrEmpty(_logPath))
        {
            return string.Empty;
        }

        try
        {
            string[] lines = System.IO.File.ReadAllLines(_logPath);
            int take = System.Math.Min(lines.Length, 6);
            string tail = string.Join("\n  ", lines[^take..]);
            return tail.Length == 0 ? string.Empty : $"; worker log ({_logPath}):\n  {tail}";
        }
        catch
        {
            return string.Empty;
        }
    }
}
