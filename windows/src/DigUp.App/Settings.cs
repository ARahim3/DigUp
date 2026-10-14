// Settings: one small JSON file. No registry writes (except the opt-in
// "start with Windows" login item, which is one value under HKCU Run).
// %LocalAppData%\DigUp\settings.json

using System.IO;
using System.Text.Json;
using Microsoft.Win32;

namespace DigUp.App;

public sealed class Settings
{
    public List<string> Folders { get; set; } = [];
    public List<string> Skipped { get; set; } = [];
    public string Hotkey { get; set; } = "ctrl+alt+space";
    /// <summary>How dark the screen gets behind search, 0..0.8.</summary>
    public double Dim { get; set; } = 0.35;
    /// <summary>Blur the screen behind search (Windows acrylic).</summary>
    public bool Blur { get; set; } = true;
    public bool Code { get; set; }
    public bool CheckUpdates { get; set; } = true;
    public string Editor { get; set; } = "auto";

    /// <summary>True when there was no settings file: first run, show setup.</summary>
    public bool IsNew { get; set; } = true;
    /// <summary>True once the one-time setup was finished. The engine never
    /// starts a blind giant index before that.</summary>
    public bool SetupDone { get; set; }

    public static string Dir =>
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DigUp");
    public static string Path => System.IO.Path.Combine(Dir, "settings.json");
    public static string IndexDir =>
        Environment.GetEnvironmentVariable("DIGUP_INDEX") is { Length: > 0 } d ? d
        : System.IO.Path.Combine(Dir, "index.noindex");

    public static readonly string[] Editors = ["auto", "code", "cursor", "devenv", "notepad++", "subl", "idea64"];

    public static Settings Load()
    {
        try
        {
            if (File.Exists(Path))
            {
                var s = JsonSerializer.Deserialize<Settings>(File.ReadAllText(Path)) ?? new Settings();
                s.IsNew = false;
                // Files from before this flag existed count as set up.
                s.SetupDone = true;
                // The old default (Shift+Alt+Space) clashes with Windows'
                // language keys: move it to the new default, unless the user
                // picked something of their own.
                if (s.Hotkey == "shift+alt+space")
                    s.Hotkey = "ctrl+alt+space";
                return s;
            }
        }
        catch { }
        var fresh = new Settings { IsNew = true };
        string docs = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        if (Directory.Exists(docs)) fresh.Folders.Add(docs);
        return fresh;
    }

    public void Save()
    {
        IsNew = false;
        Directory.CreateDirectory(Dir);
        // Atomic: a kill mid-write leaves the old file, never half a file.
        string tmp = Path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(tmp, Path, overwrite: true);
    }

    // "Start with Windows": one value under HKCU ...\Run (this user only,
    // no admin). Off removes it again. Nothing else is ever written there.
    public bool StartWithWindows
    {
        get
        {
            try
            {
                using var run = Registry.CurrentUser.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Run", false);
                return run?.GetValue("DigUp") is not null;
            }
            catch { return false; }
        }
        set
        {
            try
            {
                using var run = Registry.CurrentUser.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Run", true);
                if (run is null) return;
                if (value)
                    run.SetValue("DigUp", "\"" + Environment.ProcessPath + "\"");
                else
                    run.DeleteValue("DigUp", false);
            }
            catch { }
        }
    }
}
