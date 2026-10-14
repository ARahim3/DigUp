using Microsoft.Data.Sqlite;

namespace DigUp.Core;

/// <summary>A bound query value: int, real, text, blob or null.
/// Positional <c>?</c> placeholders are bound in order, like the Swift original.</summary>
public readonly struct SqlValue
{
    public enum SqlKind { Int, Real, Text, Blob, Null }

    public SqlKind Kind { get; }
    public long IntValue { get; }
    public double RealValue { get; }
    public string? TextValue { get; }
    public byte[]? BlobValue { get; }

    private SqlValue(SqlKind kind, long i = 0, double d = 0, string? t = null, byte[]? b = null)
    {
        Kind = kind;
        IntValue = i;
        RealValue = d;
        TextValue = t;
        BlobValue = b;
    }

    public static SqlValue Int(long v) => new(SqlKind.Int, i: v);
    public static SqlValue Real(double v) => new(SqlKind.Real, d: v);
    public static SqlValue Text(string v) => new(SqlKind.Text, t: v);
    public static SqlValue Blob(byte[] v) => new(SqlKind.Blob, b: v);
    public static readonly SqlValue Null = new(SqlKind.Null);
    public static SqlValue Of(string? v) => v is null ? Null : Text(v);
    public static SqlValue Of(double? v) => v is null ? Null : Real(v.Value);
}

/// <summary>Thin wrapper over Microsoft.Data.Sqlite (SQLite with FTS5 bundled).
/// One connection, serialized here: the index thread writes while keystroke
/// searches read, so every statement runs alone (locks re-enter, transactions
/// calling back into Query/Run on the same thread are fine).</summary>
public sealed class Database : IDisposable
{
    private readonly SqliteConnection _connection;
    private readonly object _gate = new();
    private bool _disposed;

    public Database(string path)
    {
        // Pooling=false: Dispose really closes the file (Swift lifetime semantics),
        // so index files can be moved/deleted right after the store is disposed.
        _connection = new SqliteConnection(
            new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString());
        _connection.Open();
        // WAL so readers never block the indexer; same pragmas as the Swift original.
        Execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; " +
                "PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;");
    }

    internal SqliteConnection Connection => _connection;

    public void Execute(string sql)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            using var cmd = _connection.CreateCommand();
            cmd.CommandText = sql;
            cmd.ExecuteNonQuery();
        }
    }

    /// <summary>Runs <paramref name="sql"/> with <paramref name="values"/> bound,
    /// calling <paramref name="row"/> for each result row.</summary>
    public void Query(string sql, IReadOnlyList<SqlValue> values, Action<SqliteDataReader> row)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            using var cmd = _connection.CreateCommand();
            // Microsoft.Data.Sqlite matches parameters by name, so the Swift-style
            // positional '?' placeholders are renamed to @p0.. (@pN) up front,
            // skipping '?' inside quoted literals (e.g. the FTS5 tokenizer spec).
            cmd.CommandText = NamePlaceholders(sql);
            Bind(cmd, values);
            using var reader = cmd.ExecuteReader();
            while (reader.Read())
                row(reader);
        }
    }

    public void Query(string sql, Action<SqliteDataReader> row) =>
        Query(sql, Array.Empty<SqlValue>(), row);

    public void Run(string sql, IReadOnlyList<SqlValue>? values = null) =>
        Query(sql, values ?? Array.Empty<SqlValue>(), _ => { });

    [System.Diagnostics.CodeAnalysis.SuppressMessage("Design", "CA1031:Do not catch general exception types",
        Justification = "Rollback must be attempted before rethrowing, mirroring the Swift original.")]
    public T Transaction<T>(Func<T> body)
    {
        Execute("BEGIN IMMEDIATE");
        try
        {
            var result = body();
            Execute("COMMIT");
            return result;
        }
        catch
        {
            try { Execute("ROLLBACK"); } catch { }
            throw;
        }
    }

    public void Transaction(Action body) => Transaction(() => { body(); return 0; });

    public long LastInsertId
    {
        get
        {
            lock (_gate)
            {
                ObjectDisposedException.ThrowIf(_disposed, this);
                using var cmd = _connection.CreateCommand();
                cmd.CommandText = "SELECT last_insert_rowid()";
                return (long)(cmd.ExecuteScalar() ?? 0L);
            }
        }
    }

    private static void Bind(SqliteCommand cmd, IReadOnlyList<SqlValue> values)
    {
        for (int i = 0; i < values.Count; i++)
        {
            var p = cmd.CreateParameter();
            p.ParameterName = "@p" + i;
            var v = values[i];
            switch (v.Kind)
            {
                case SqlValue.SqlKind.Int:
                    p.Value = v.IntValue;
                    break;
                case SqlValue.SqlKind.Real:
                    p.Value = v.RealValue;
                    break;
                case SqlValue.SqlKind.Text:
                    p.Value = (object)(v.TextValue ?? string.Empty);
                    p.SqliteType = SqliteType.Text;
                    break;
                case SqlValue.SqlKind.Blob:
                    p.Value = (object)(v.BlobValue ?? Array.Empty<byte>());
                    p.SqliteType = SqliteType.Blob;
                    break;
                default:
                    p.Value = DBNull.Value;
                    break;
            }
            cmd.Parameters.Add(p);
        }
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        _connection.Dispose();
    }

    private static string NamePlaceholders(string sql)
    {
        var sb = new System.Text.StringBuilder(sql.Length + 16);
        int index = 0;
        char quote = '\0';
        for (int i = 0; i < sql.Length; i++)
        {
            char c = sql[i];
            if (quote != '\0')
            {
                sb.Append(c);
                if (c == quote)
                {
                    if (i + 1 < sql.Length && sql[i + 1] == quote)
                    {
                        sb.Append(sql[i + 1]);
                        i++;
                    }
                    else
                    {
                        quote = '\0';
                    }
                }
            }
            else if (c == '\'' || c == '"')
            {
                quote = c;
                sb.Append(c);
            }
            else if (c == '?')
            {
                sb.Append("@p");
                sb.Append(index++);
            }
            else
            {
                sb.Append(c);
            }
        }
        return sb.ToString();
    }
}

internal static class ReaderExtensions
{
    public static string? NullableText(this SqliteDataReader r, int i) =>
        r.IsDBNull(i) ? null : r.GetString(i);

    public static byte[]? NullableBlob(this SqliteDataReader r, int i) =>
        r.IsDBNull(i) ? null : r.GetFieldValue<byte[]>(i);
}
