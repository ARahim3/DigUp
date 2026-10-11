// Which folders DigUp searches: the folders you chose, minus the folders you
// skipped inside them. Ports FolderSelection (FolderSelection.swift).
// Comparisons are case-insensitive: the right default on Windows, where the
// file system (and FileSystemWatcher events) do not preserve case.
using System;
using System.Collections.Generic;

namespace DigUp.Core;

/// <summary>A folder's checkbox: all of it, some of its subfolders, or none. (FolderSelection.swift:13)</summary>
public enum FolderMark
{
    On,
    Mixed,
    Off,
}

public sealed class FolderSelection
{
    public List<string> Chosen { get; private set; }

    public List<string> Skipped { get; private set; }

    /// <summary>Folders already searched (when Settings adds more): whatever is clicked, they stay.</summary>
    public List<string> Kept { get; }

    public FolderSelection(
        IEnumerable<string>? chosen = null,
        IEnumerable<string>? skipped = null,
        IEnumerable<string>? kept = null)
    {
        Chosen = Unique(chosen);
        Skipped = Unique(skipped);
        Kept = Unique(kept);
    }

    /// <summary>Whether <paramref name="path"/> (a folder or a file) is searched. (FolderSelection.swift:28)</summary>
    public bool IsSearched(string path)
    {
        var folders = new List<string>(Kept);
        folders.AddRange(Chosen);
        return IsSearched(path, folders, Skipped);
    }

    public static bool IsSearched(string path, IEnumerable<string> folders, IEnumerable<string> skipped)
    {
        var skips = skipped as IReadOnlyCollection<string> ?? new List<string>(skipped);
        foreach (string folder in folders)
        {
            if (!path.Equals(folder, StringComparison.OrdinalIgnoreCase) && !IsInside(path, folder))
            {
                continue;
            }

            bool cut = false;
            foreach (string skip in skips)
            {
                if (IsInside(skip, folder)
                    && (path.Equals(skip, StringComparison.OrdinalIgnoreCase) || IsInside(path, skip)))
                {
                    cut = true;
                    break;
                }
            }

            if (!cut)
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>The closest chosen (or kept) folder that searches <paramref name="path"/>. (FolderSelection.swift:40)</summary>
    public string? SearchedAs(string path)
    {
        var folders = new List<string>(Kept);
        folders.AddRange(Chosen);
        string? best = null;
        foreach (string folder in folders)
        {
            if ((path.Equals(folder, StringComparison.OrdinalIgnoreCase) || IsInside(path, folder))
                && IsSearched(path, new[] { folder }, Skipped)
                && (best == null || folder.Length > best.Length))
            {
                best = folder;
            }
        }

        return best;
    }

    /// <summary>Kept and chosen folders, without those another one already searches whole. (FolderSelection.swift:47)</summary>
    public List<string> Folders()
    {
        var all = Unique(Kept);
        all.AddRange(Unique(Chosen));
        var result = new List<string>();
        foreach (string folder in all)
        {
            bool covered = false;
            foreach (string other in all)
            {
                if (!other.Equals(folder, StringComparison.OrdinalIgnoreCase)
                    && IsInside(folder, other)
                    && IsSearched(folder, new[] { other }, Skipped))
                {
                    covered = true;
                    break;
                }
            }

            if (!covered)
            {
                result.Add(folder);
            }
        }

        return result;
    }

    /// <summary>The skips that leave something out (inside a folder that's searched). (FolderSelection.swift:58)</summary>
    public List<string> EffectiveSkips()
    {
        List<string> folders = Folders();
        var result = new List<string>();
        foreach (string skip in Skipped)
        {
            foreach (string folder in folders)
            {
                if (IsInside(skip, folder))
                {
                    result.Add(skip);
                    break;
                }
            }
        }

        return result;
    }

    /// <summary>Mixed when some direct subfolders are skipped (it is searched) or chosen (it isn't). (FolderSelection.swift:65)</summary>
    public FolderMark Mark(string folder)
    {
        if (IsSearched(folder))
        {
            foreach (string skip in Skipped)
            {
                if (Parent(skip).Equals(folder, StringComparison.OrdinalIgnoreCase) && !IsSearched(skip))
                {
                    return FolderMark.Mixed;
                }
            }

            return FolderMark.On;
        }

        var all = new List<string>(Kept);
        all.AddRange(Chosen);
        foreach (string choice in all)
        {
            if (Parent(choice).Equals(folder, StringComparison.OrdinalIgnoreCase))
            {
                return FolderMark.Mixed;
            }
        }

        return FolderMark.Off;
    }

    /// <summary>Checks or unchecks a folder and its subfolders. (FolderSelection.swift:73)</summary>
    public void SetFolder(string folder, bool on)
    {
        Skipped.RemoveAll(s => Parent(s).Equals(folder, StringComparison.OrdinalIgnoreCase));
        Chosen.RemoveAll(c => Parent(c).Equals(folder, StringComparison.OrdinalIgnoreCase));
        SetSubfolder(folder, on);
    }

    /// <summary>Checks or unchecks one folder, leaving the choices inside it. (FolderSelection.swift:80)</summary>
    public void SetSubfolder(string folder, bool on)
    {
        if (on)
        {
            Skipped.RemoveAll(s => s.Equals(folder, StringComparison.OrdinalIgnoreCase));
            if (!IsSearched(folder))
            {
                Chosen.Add(folder);
            }
        }
        else
        {
            Chosen.RemoveAll(c => c.Equals(folder, StringComparison.OrdinalIgnoreCase));
            if (IsSearched(folder))
            {
                Skipped.Add(folder);
            }
        }
    }

    /// <summary>Stops skipping <paramref name="folder"/> (without choosing it). (FolderSelection.swift:91)</summary>
    public void Unskip(string folder)
    {
        Skipped.RemoveAll(s => s.Equals(folder, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>Whether <paramref name="path"/> is strictly inside <paramref name="folder"/>. (FolderSelection.swift:95)</summary>
    public static bool IsInside(string path, string folder)
    {
        if (folder.EndsWith("/") || folder.EndsWith("\\"))
        {
            return path.StartsWith(folder, StringComparison.OrdinalIgnoreCase);
        }

        return path.StartsWith(folder + "\\", StringComparison.OrdinalIgnoreCase)
            || path.StartsWith(folder + "/", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>The enclosing folder. (FolderSelection.swift:99)</summary>
    public static string Parent(string path)
    {
        string trimmed = path.TrimEnd('\\', '/');
        int i = trimmed.LastIndexOfAny(new[] { '\\', '/' });
        if (i < 0)
        {
            return string.Empty;
        }

        if (i == 0)
        {
            return trimmed.Substring(0, 1);
        }

        string parent = trimmed.Substring(0, i);
        if (parent.EndsWith(":"))
        {
            parent += "\\";
        }

        return parent;
    }

    /// <summary>
    /// The canonical path: symlinks resolved, like Swift's realpath
    /// (FolderSelection.swift:104). Falls back to the input when unknown.
    /// </summary>
    public static string RealPath(string path)
    {
        try
        {
            string full = System.IO.Path.GetFullPath(path);
            System.IO.FileSystemInfo? info = System.IO.Directory.Exists(full)
                ? (System.IO.FileSystemInfo)new System.IO.DirectoryInfo(full)
                : System.IO.File.Exists(full)
                    ? new System.IO.FileInfo(full)
                    : null;
            return info?.ResolveLinkTarget(returnFinalTarget: true)?.FullName ?? full;
        }
        catch
        {
            return path;
        }
    }

    private static List<string> Unique(IEnumerable<string>? paths)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new List<string>();
        if (paths == null)
        {
            return result;
        }

        foreach (string path in paths)
        {
            if (seen.Add(path))
            {
                result.Add(path);
            }
        }

        return result;
    }
}
