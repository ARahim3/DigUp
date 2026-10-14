// The model runner: EmbeddingGemma 2 text + mtmd image/audio encoders
// feeding the text model, mean-pooled + L2-normalized per input.
// Port of LlamaEmbedder (Sources/LlamaRuntime/LlamaEmbedder.swift):
// same budgets, same batching (16 inputs, 2048/512 tokens), same framing.
// Frees ~1 GB (0.25 GB text-only) on Dispose. One thread at a time.

using System.Runtime.InteropServices;
using System.Text;

namespace DigUp.Embed;

internal sealed class Embedder : IDisposable
{
    internal static readonly int[] Budgets = [70, 140, 280, 560, 1120];
    private const int MaxSeqs = 16;
    private const int Dim = 768;

    private IntPtr _model, _ctx, _media, _batch, _vocab;
    private int _dimOut, _rowSize, _maxTokens;
    private int _seqs, _tokens, _pos;
    private bool _dead;
    private readonly object _gate = new();

    public string Revision { get; } = "bfcd298762cc34d0357ece5ebdd31791a3a374d8";
    public bool TextOnly { get; }
    public double LoadSeconds { get; private set; }

    public Embedder(string textPath, string? mediaPath, bool textOnly)
    {
        TextOnly = textOnly;
        var started = DateTime.UtcNow;
        Native.CheckLayouts();
        Native.InstallLog();
        Native.llama_backend_init();

        if (!textOnly && mediaPath is null)
            throw new InvalidOperationException("mmproj file (images and audio) isn't downloaded yet");

        var mp = Native.llama_model_default_params();
        mp.NGpuLayers = 999;
        _model = Native.llama_model_load_from_file(textPath, mp);
        if (_model == IntPtr.Zero) throw new InvalidOperationException($"can't load {textPath}");

        try
        {
            _maxTokens = textOnly ? 512 : 2048;
            var cp = Native.llama_context_default_params();
            cp.NCtx = cp.NBatch = cp.NUbatch = (uint)_maxTokens;
            cp.NSeqMax = MaxSeqs;
            // Use the whole CPU for the parts that run there (the GPU does the rest).
            cp.NThreads = cp.NThreadsBatch = Environment.ProcessorCount;
            cp.KvUnified = true;
            cp.Embeddings = true;
            cp.PoolingType = 1; // MEAN
            _ctx = Native.llama_init_from_model(_model, cp);
            if (_ctx == IntPtr.Zero) throw new InvalidOperationException("can't create a llama.cpp context");

            try
            {
                if (mediaPath is not null && !textOnly)
                {
                    var mprm = Native.mtmd_context_params_default();
                    mprm.UseGpu = true;
                    mprm.PrintTimings = false;
                    mprm.Warmup = true;
                    mprm.NThreads = Environment.ProcessorCount;
                    mprm.ImageMinTokens = 1; // never rescale: images arrive at final size
                    mprm.ImageMaxTokens = 1120;
                    _media = Native.mtmd_init_from_file(mediaPath, _model, mprm);
                    if (_media == IntPtr.Zero) throw new InvalidOperationException($"can't load {mediaPath}");
                }
                _batch = Native.llama_batch_ext_init(_ctx);
                if (_batch == IntPtr.Zero) throw new InvalidOperationException("can't make a batch");
                _vocab = Native.llama_model_get_vocab(_model);
                _dimOut = Native.llama_model_n_embd_out(_model);
                _rowSize = Native.llama_model_n_embd_inp(_model);
                if (_dimOut != Dim) throw new InvalidOperationException($"model says dim {_dimOut}, want {Dim}");
                // First calls build the GPU pipelines: pay now, while the panel opens.
                EmbedTexts(["task: search result | query: warm up"]);
                EmbedTexts(["task: search result | query: warm up"]);
            }
            catch { Close(); throw; }
        }
        catch { Native.llama_model_free(_model); _model = IntPtr.Zero; throw; }

        LoadSeconds = Math.Round((DateTime.UtcNow - started).TotalSeconds, 2);
    }

    public float[][] EmbedTexts(IList<string> texts)
    {
        lock (_gate)
        {
            ThrowIfDead();
            Reset();
            var vecs = new List<float[]>();
            foreach (string t in texts)
            {
                int[] toks = Tokenize(t);
                if (_seqs == MaxSeqs || _tokens + toks.Length > _maxTokens)
                    vecs.AddRange(Run());
                Begin();
                foreach (int tok in toks) AddToken(tok);
            }
            if (_seqs > 0) vecs.AddRange(Run());
            return vecs.ToArray();
        }
    }

    public (float[]? V, string? E) EmbedImageFile(string path, int budget)
    {
        lock (_gate)
        {
            try
            {
                if (_media == IntPtr.Zero) throw new InvalidOperationException("started --text-only");
                if (!Budgets.Contains(budget)) throw new InvalidOperationException("budget must be one of 70,140,280,560,1120");
                (byte[] rgb, int w, int h) = DecodePng(path);
                var target = ImageSizing.TargetSize(h, w, budget)
                    ?? throw new InvalidOperationException($"image too thin to embed: {path}");
                if (target != (h, w)) rgb = ImageSizing.ResizeBicubic(rgb, w, h, target.W, target.H);
                IntPtr bmp = Native.mtmd_bitmap_init((uint)target.W, (uint)target.H, rgb);
                if (bmp == IntPtr.Zero) throw new InvalidOperationException($"can't read {path}");
                try { return (EmbedBitmap(bmp), null); }
                finally { Native.mtmd_bitmap_free(bmp); }
            }
            catch (Exception ex) { return (null, Chop(ex.Message)); }
        }
    }

    public (float[]? V, string? E) EmbedAudioFile(string path, int sampleRate)
    {
        lock (_gate)
        {
            try
            {
                if (_media == IntPtr.Zero) throw new InvalidOperationException("started --text-only");
                float[] samples = ReadWavMono(path);
                int limit = 30 * sampleRate; // model ignores anything past 30 s
                if (samples.Length > limit) samples = samples[..limit];
                IntPtr bmp = Native.mtmd_bitmap_init_from_audio((UIntPtr)(uint)samples.Length, samples);
                if (bmp == IntPtr.Zero) throw new InvalidOperationException($"can't read {path}");
                try { return (EmbedBitmap(bmp), null); }
                finally { Native.mtmd_bitmap_free(bmp); }
            }
            catch (Exception ex) { return (null, Chop(ex.Message)); }
        }
    }

    private float[] EmbedBitmap(IntPtr bmp)
    {
        IntPtr chunks = Native.mtmd_input_chunks_init();
        if (chunks == IntPtr.Zero) throw new InvalidOperationException("no chunks");
        try
        {
            byte[] marker = Encoding.UTF8.GetBytes(Marshal.PtrToStringUTF8(Native.mtmd_default_marker()) ?? "<__media__>");
            unsafe
            {
                fixed (byte* mp = marker)
                {
                    var text = new Native.InputText
                    {
                        Text = (IntPtr)mp,
                        TextLen = (UIntPtr)(uint)marker.Length,
                        AddSpecial = true,
                        ParseSpecial = true,
                    };
                    IntPtr[] arr = [bmp];
                    int st = Native.mtmd_tokenize(_media, chunks, ref text, arr, (UIntPtr)1);
                    if (st != 0) throw new InvalidOperationException($"can't tokenize ({st})");
                }
            }
            Reset();
            Begin();
            ulong n = Native.mtmd_input_chunks_size(chunks).ToUInt64();
            for (ulong i = 0; i < n; i++)
            {
                IntPtr chunk = Native.mtmd_input_chunks_get(chunks, (UIntPtr)i);
                if (Native.mtmd_input_chunk_get_type(chunk) == 0) // TEXT
                {
                    IntPtr tp = Native.mtmd_input_chunk_get_tokens_text(chunk, out UIntPtr cnt);
                    int c = (int)cnt.ToUInt64();
                    int[] toks = new int[c];
                    Marshal.Copy(tp, toks, 0, c);
                    foreach (int tok in toks) AddToken(tok);
                }
                else
                {
                    if (Native.mtmd_encode_chunk(_media, chunk) != 0)
                        throw new InvalidOperationException("the encoder failed on this file");
                    IntPtr rows = Native.mtmd_get_output_embd(_media);
                    if (rows == IntPtr.Zero) throw new InvalidOperationException("the encoder failed on this file");
                    int count = (int)Native.mtmd_input_chunk_get_n_tokens(chunk).ToUInt64();
                    AddRows(rows, count);
                }
            }
            return Run()[0];
        }
        finally { Native.mtmd_input_chunks_free(chunks); }
    }

    // <bos> text <eos>, cut like transformers (keep both special tokens).
    private int[] Tokenize(string text)
    {
        byte[] utf8 = Encoding.UTF8.GetBytes(text);
        int[] toks = new int[utf8.Length + 8];
        int n = Native.llama_tokenize(_vocab, utf8, utf8.Length, toks, toks.Length, true, true);
        if (n < 0)
        {
            toks = new int[-n];
            n = Native.llama_tokenize(_vocab, utf8, utf8.Length, toks, toks.Length, true, true);
        }
        if (n < 0) throw new InvalidOperationException("can't tokenize this text");
        if (toks.Length != n) Array.Resize(ref toks, n);
        if (toks.Length > _maxTokens)
        {
            int eos = Native.llama_vocab_eos(_vocab);
            var cut = new int[_maxTokens];
            Array.Copy(toks, cut, _maxTokens - 1);
            cut[_maxTokens - 1] = eos;
            toks = cut;
        }
        return toks;
    }

    private void Begin() { _seqs++; _pos = 0; }

    private void Reset()
    {
        if (_batch != IntPtr.Zero) Native.llama_batch_ext_clear(_batch);
        _seqs = 0; _tokens = 0;
    }

    private void AddToken(int token)
    {
        int idx = Native.llama_batch_ext_add_token(_batch, _seqs - 1, token);
        if (idx < 0) throw new InvalidOperationException($"batch full ({idx})");
        Place(idx);
    }

    private unsafe void AddRows(IntPtr rows, int count)
    {
        float* baseP = (float*)rows.ToPointer();
        for (int r = 0; r < count; r++)
        {
            var embd = new Native.Embd
            {
                Data = (IntPtr)(baseP + (nint)r * _rowSize),
                NRows = (UIntPtr)1,
                NEmbd = (UIntPtr)(uint)_rowSize,
            };
            int idx = Native.llama_batch_ext_add_embd(_batch, _seqs - 1, embd);
            if (idx < 0) throw new InvalidOperationException($"batch full ({idx})");
            Place(idx);
        }
    }

    private void Place(int idx)
    {
        int[] pos = [_pos, 0, 0, 0];
        if (!Native.llama_batch_ext_set_pos(_batch, idx, pos)) throw new InvalidOperationException($"can't place token {idx}");
        if (!Native.llama_batch_ext_set_output_embd(_batch, idx, true)) throw new InvalidOperationException($"can't place token {idx}");
        _pos++;
        _tokens++;
    }

    private float[] RunOne(int seq)
    {
        IntPtr p = Native.llama_get_embeddings_seq(_ctx, seq);
        if (p == IntPtr.Zero) throw new InvalidOperationException($"no pooled embedding for input {seq}");
        float[] v = new float[_dimOut];
        Marshal.Copy(p, v, 0, _dimOut);
        double sum = 0;
        for (int i = 0; i < v.Length; i++) sum += (double)v[i] * v[i];
        float s = sum > 0 ? (float)(1 / Math.Sqrt(sum)) : 0;
        for (int i = 0; i < v.Length; i++) v[i] *= s;
        return v;
    }

    private List<float[]> Run()
    {
        try
        {
            int st = Native.llama_process(_ctx, 0 /* ENCODE */, _batch);
            if (st != 0) throw new InvalidOperationException($"llama_process failed ({st})");
            var vecs = new List<float[]>();
            for (int s = 0; s < _seqs; s++) vecs.Add(RunOne(s));
            return vecs;
        }
        finally { Reset(); }
    }

    private void ThrowIfDead()
    {
        if (_dead || _ctx == IntPtr.Zero) throw new ObjectDisposedException("embedder");
    }

    private void Close()
    {
        if (_batch != IntPtr.Zero) { Native.llama_batch_ext_free(_batch); _batch = IntPtr.Zero; }
        if (_media != IntPtr.Zero) { Native.mtmd_free(_media); _media = IntPtr.Zero; }
        if (_ctx != IntPtr.Zero) { Native.llama_free(_ctx); _ctx = IntPtr.Zero; }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_dead) return;
            _dead = true;
            Close();
            if (_model != IntPtr.Zero) { Native.llama_model_free(_model); _model = IntPtr.Zero; }
        }
    }

    private static string Chop(string s) => s.Length <= 300 ? s : s[..300];

    // Prepared PNG (exact-size RGB) -> packed RGB bytes + size.
    internal static (byte[] Rgb, int W, int H) DecodePng(string path)
    {
        using var bmp = new System.Drawing.Bitmap(path);
        int w = bmp.Width, h = bmp.Height;
        if (w <= 0 || h <= 0) throw new InvalidOperationException($"can't read {path}");
        var rect = new System.Drawing.Rectangle(0, 0, w, h);
        var data = bmp.LockBits(rect, System.Drawing.Imaging.ImageLockMode.ReadOnly,
            System.Drawing.Imaging.PixelFormat.Format24bppRgb);
        try
        {
            var rgb = new byte[w * h * 3];
            if (data.Stride == w * 3)
                Marshal.Copy(data.Scan0, rgb, 0, rgb.Length);
            else
                for (int y = 0; y < h; y++)
                    Marshal.Copy(data.Scan0 + y * data.Stride, rgb, y * w * 3, w * 3);
            // 24bpp is BGR: flip to RGB for mtmd.
            for (int i = 0; i < rgb.Length; i += 3) (rgb[i], rgb[i + 2]) = (rgb[i + 2], rgb[i]);
            return (rgb, w, h);
        }
        finally { bmp.UnlockBits(data); }
    }

    // Our own WAVs (44-byte header, s16 mono 16 kHz) -> float samples.
    internal static float[] ReadWavMono(string path)
    {
        using var fs = File.OpenRead(path);
        using var br = new BinaryReader(fs);
        byte[] head = br.ReadBytes(44);
        if (head.Length < 44 || Encoding.ASCII.GetString(head, 0, 4) != "RIFF")
            throw new InvalidOperationException($"not a WAV file: {path}");
        int fmt = BitConverter.ToUInt16(head, 20);
        int ch = BitConverter.ToUInt16(head, 22);
        if (fmt != 1 || ch != 1) throw new InvalidOperationException($"want 16-bit mono WAV: {path}");
        byte[] raw = br.ReadBytes((int)(fs.Length - fs.Position));
        int n = raw.Length / 2;
        var floats = new float[n];
        for (int i = 0; i < n; i++)
            floats[i] = BitConverter.ToInt16(raw, i * 2) / 32768f;
        return floats;
    }
}
