// Global hotkey: Ctrl+Alt+Space by default (remappable in Settings).
// (Shift+Alt+Space was the first default; Windows itself reacts to
// Shift+Alt for switching input language, so it had to go.)
// Uses RegisterHotKey on this thread (no window). Win+Space can't be taken:
// Windows keeps it for switching input language.

using System.Runtime.InteropServices;

namespace DigUp.App;

public sealed class Hotkey : IDisposable
{
    private const int HOTKEY_ID = 0xD16;
    private bool _on;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private const uint MOD_ALT = 0x0001, MOD_CONTROL = 0x0002, MOD_SHIFT = 0x0004, MOD_WIN = 0x0008, MOD_NOREPEAT = 0x4000;
    private const uint VK_SPACE = 0x20;

    /// <summary>"shift+alt+space", "ctrl+alt+space" or "shift+win+space". False when taken.</summary>
    public bool Register(string spec)
    {
        Dispose();
        uint mod = 0;
        foreach (string part in spec.ToLowerInvariant().Split('+', StringSplitOptions.RemoveEmptyEntries))
        {
            string p = part.Trim();
            if (p == "shift") mod |= MOD_SHIFT;
            else if (p == "alt") mod |= MOD_ALT;
            else if (p is "ctrl" or "control") mod |= MOD_CONTROL;
            else if (p is "win" or "windows" or "cmd") mod |= MOD_WIN;
        }
        _on = RegisterHotKey(IntPtr.Zero, HOTKEY_ID, mod | MOD_NOREPEAT, VK_SPACE);
        return _on;
    }

    public void Dispose()
    {
        if (_on) { UnregisterHotKey(IntPtr.Zero, HOTKEY_ID); _on = false; }
    }
}
