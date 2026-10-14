// Index-or-skip decision for one file. Ports Classification (Rules.swift:4).

namespace DigUp.Core;

/// <summary>
/// What the crawler does with one file. Ports Classification (Rules.swift:4):
/// index it, skip it with a reason worth reporting, or ignore a type DigUp
/// does not handle at all.
/// </summary>
public abstract record Classification
{
    /// <summary>Index the file, as this kind.</summary>
    public sealed record Index(FileKind Kind) : Classification;

    /// <summary>Leave the file out, counted under <see cref="Reason"/>.</summary>
    public sealed record Skip(string Reason) : Classification;

    /// <summary>A type DigUp does not handle at all (uncounted beyond "other type").</summary>
    public sealed record Ignore : Classification
    {
        public static readonly Ignore Instance = new();
    }
}
