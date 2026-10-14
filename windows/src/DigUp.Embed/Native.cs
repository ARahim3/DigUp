// Native bridge: EmbeddingGemma 2 on llama.cpp + mtmd, one thread at a time.
// Exact port of Sources/LlamaRuntime/LlamaEmbedder.swift: same prompts in,
// same framing (<bos> text <eos>, marker + soft tokens), same mean-pooled
// L2-normalized vectors out. Struct layouts are checked at startup
// (Marshal.SizeOf) so a wrong layout fails loud, never silent.
// Needs llama.dll + mtmd.dll (+ ggml*.dll) next to digup-embed.exe:
// build them with windows\scripts\build-llama-windows.ps1.

using System.Runtime.InteropServices;
using System.Text;

namespace DigUp.Embed;

internal static class Native
{
    private const string LlamaLib = "llama";
    private const string MtmdLib = "mtmd";

    // Keep the log callback alive: native code calls it for years.
    private static readonly LogCallback _logCb = OnLog;
    private static int _lastLevel = 2;

    internal enum LogLevel { None = 0, Debug = 1, Info = 2, Warn = 3, Error = 4, Cont = 5 }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void LogCallback(int level, IntPtr text, IntPtr userData);

    private static void OnLog(int level, IntPtr text, IntPtr userData)
    {
        if (level != (int)LogLevel.Cont) _lastLevel = level;
        if (_lastLevel < (int)LogLevel.Warn) return;
        string s = Marshal.PtrToStringUTF8(text) ?? "";
        Console.Error.Write(s);
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    internal struct ModelParams
    {
        public IntPtr Devices;
        public IntPtr TensorBuftOverrides;
        public int NGpuLayers;
        public int SplitMode;
        public int LoadMode;
        public int LazyMode;
        public int MainGpu;
        public IntPtr TensorSplit;
        public IntPtr ProgressCallback;
        public IntPtr ProgressUserData;
        public IntPtr KvOverrides;
        [MarshalAs(UnmanagedType.I1)] public bool VocabOnly;
        [MarshalAs(UnmanagedType.I1)] public bool CheckTensors;
        [MarshalAs(UnmanagedType.I1)] public bool UseExtraBufts;
        [MarshalAs(UnmanagedType.I1)] public bool NoHost;
        [MarshalAs(UnmanagedType.I1)] public bool NoAlloc;
        [MarshalAs(UnmanagedType.I1)] public bool LoadMtp;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    internal struct ContextParams
    {
        public uint NCtx, NBatch, NUbatch, NSeqMax, NRsSeq, NOutputsMax, NOutputsMaxPerSeq;
        public int NThreads, NThreadsBatch;
        public int CtxType, RopeScalingType, PoolingType, AttentionType, FlashAttnType;
        public float RopeFreqBase, RopeFreqScale, YarnExtFactor, YarnAttnFactor, YarnBetaFast, YarnBetaSlow;
        public uint YarnOrigCtx;
        public float DefragThold;
        public IntPtr CbEval;
        public IntPtr CbEvalUserData;
        public int TypeK, TypeV;
        public IntPtr AbortCallback;
        public IntPtr AbortCallbackData;
        [MarshalAs(UnmanagedType.I1)] public bool Embeddings;
        [MarshalAs(UnmanagedType.I1)] public bool OffloadKqv;
        [MarshalAs(UnmanagedType.I1)] public bool NoPerf;
        [MarshalAs(UnmanagedType.I1)] public bool OpOffload;
        [MarshalAs(UnmanagedType.I1)] public bool SwaFull;
        [MarshalAs(UnmanagedType.I1)] public bool KvUnified;
        public IntPtr Samplers;
        public UIntPtr NSamplers;
        public IntPtr CtxOther;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    internal struct Embd
    {
        public IntPtr Data;
        public UIntPtr NRows;
        public UIntPtr NEmbd;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    internal struct MtmdParams
    {
        [MarshalAs(UnmanagedType.I1)] public bool UseGpu;
        public IntPtr Device;
        [MarshalAs(UnmanagedType.I1)] public bool PrintTimings;
        public int NThreads;
        public IntPtr ImageMarker;
        public IntPtr MediaMarker;
        public int FlashAttnType;
        [MarshalAs(UnmanagedType.I1)] public bool Warmup;
        public int ImageMinTokens;
        public int ImageMaxTokens;
        public IntPtr CbEval;
        public IntPtr CbEvalUserData;
        public int BatchMaxTokens;
        public IntPtr ProgressCallback;
        public IntPtr ProgressUserData;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    internal struct InputText
    {
        public IntPtr Text;
        public UIntPtr TextLen;
        [MarshalAs(UnmanagedType.I1)] public bool AddSpecial;
        [MarshalAs(UnmanagedType.I1)] public bool ParseSpecial;
    }

    internal static void CheckLayouts()
    {
        // x64 sizes from the headers (llama.h, mtmd.h). Wrong = loud fail.
        Check<ModelParams>(80);
        Check<ContextParams>(160);
        Check<Embd>(24);
        Check<MtmdParams>(96);
        Check<InputText>(24);
        static void Check<T>(int want)
        {
            int got = Marshal.SizeOf<T>();
            if (got != want) throw new InvalidOperationException(
                $"native layout of {typeof(T).Name} is {got} bytes, want {want}: rebuild against the pinned headers");
        }
    }

    // --- llama ---
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern void llama_log_set(LogCallback cb, IntPtr userData);
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern void llama_backend_init();
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern ModelParams llama_model_default_params();
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)] internal static extern IntPtr llama_model_load_from_file(string path, ModelParams prm);
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern void llama_model_free(IntPtr model);
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern ContextParams llama_context_default_params();
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr llama_init_from_model(IntPtr model, ContextParams prm);
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern void llama_free(IntPtr ctx);
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr llama_model_get_vocab(IntPtr model);
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern int llama_model_n_embd_out(IntPtr model);
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern int llama_model_n_embd_inp(IntPtr model);
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr llama_batch_ext_init(IntPtr ctx);
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern void llama_batch_ext_free(IntPtr batch);
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern void llama_batch_ext_clear(IntPtr batch);
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern int llama_batch_ext_add_token(IntPtr batch, int seq, int token);
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern int llama_batch_ext_add_embd(IntPtr batch, int seq, Embd embd);
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern bool llama_batch_ext_set_output_embd(IntPtr batch, int idx, [MarshalAs(UnmanagedType.I1)] bool value);
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern bool llama_batch_ext_set_pos(IntPtr batch, int idx, [In] int[] pos);
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern int llama_process(IntPtr ctx, int type, IntPtr batch);
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr llama_get_embeddings_seq(IntPtr ctx, int seq);
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)] internal static extern int llama_vocab_eos(IntPtr vocab);
    [DllImport(LlamaLib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int llama_tokenize(IntPtr vocab, byte[] text, int textLen,
        [Out] int[] tokens, int maxTokens,
        [MarshalAs(UnmanagedType.I1)] bool addSpecial, [MarshalAs(UnmanagedType.I1)] bool parseSpecial);

    // --- mtmd ---
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern void mtmd_log_set(LogCallback cb, IntPtr userData);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr mtmd_default_marker();
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern MtmdParams mtmd_context_params_default();
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)] internal static extern IntPtr mtmd_init_from_file(string path, IntPtr textModel, MtmdParams prm);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern void mtmd_free(IntPtr ctx);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern int mtmd_get_audio_sample_rate(IntPtr ctx);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr mtmd_bitmap_init(uint nx, uint ny, byte[] data);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr mtmd_bitmap_init_from_audio(UIntPtr nSamples, float[] data);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern uint mtmd_bitmap_get_nx(IntPtr bmp);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern uint mtmd_bitmap_get_ny(IntPtr bmp);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr mtmd_bitmap_get_data(IntPtr bmp);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern UIntPtr mtmd_bitmap_get_n_bytes(IntPtr bmp);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern bool mtmd_bitmap_is_audio(IntPtr bmp);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern void mtmd_bitmap_free(IntPtr bmp);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr mtmd_input_chunks_init();
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern UIntPtr mtmd_input_chunks_size(IntPtr chunks);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr mtmd_input_chunks_get(IntPtr chunks, UIntPtr idx);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern void mtmd_input_chunks_free(IntPtr chunks);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern int mtmd_input_chunk_get_type(IntPtr chunk);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr mtmd_input_chunk_get_tokens_text(IntPtr chunk, out UIntPtr nTokens);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern UIntPtr mtmd_input_chunk_get_n_tokens(IntPtr chunk);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern int mtmd_tokenize(IntPtr ctx, IntPtr chunks, ref InputText text, IntPtr[] bitmaps, UIntPtr n);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern int mtmd_encode_chunk(IntPtr ctx, IntPtr chunk);
    [DllImport(MtmdLib, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr mtmd_get_output_embd(IntPtr ctx);

    internal static void InstallLog()
    {
        llama_log_set(_logCb, IntPtr.Zero);
        try { mtmd_log_set(_logCb, IntPtr.Zero); } catch { }
    }
}
