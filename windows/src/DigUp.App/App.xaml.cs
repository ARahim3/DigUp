// App start: one copy only, tray icon, global hotkey, hidden search panel.
// First run opens setup (folders, code, model download); later runs go
// straight to the tray. No admin. No services. Settings + index live in
// %LocalAppData%\DigUp.

using System.IO;
using System.Windows;
using System.Windows.Interop;
using DigUp.Core;
using WinForms = System.Windows.Forms;

namespace DigUp.App;

public partial class App : System.Windows.Application
{
    private static Mutex? _single;
    private WinForms.NotifyIcon? _tray;
    private MainWindow? _panel;
    private Engine? _engine;
    private Hotkey? _hotkey;
    private FileSystemWatcherRunner? _watcher;
    private Settings? _settings;
    private bool _hotkeyHooked;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // No silent deaths: anything escaping to the top is logged and shown.
        DispatcherUnhandledException += (_, ex) =>
        {
            ErrorLog.Write("ui: " + ex.Exception.Message);
            ShowNote("Something went wrong (" + FirstLine(ex.Exception.Message) + "). DigUp keeps running.");
            ex.Handled = true;
        };
        TaskScheduler.UnobservedTaskException += (_, ex) =>
        {
            ErrorLog.Write("task: " + ex.Exception.Message);
            ex.SetObserved();
        };
        AppDomain.CurrentDomain.UnhandledException += (_, ex) =>
        {
            ErrorLog.Write("fatal: " + (ex.ExceptionObject as Exception)?.Message);
        };
        _single = new Mutex(true, @"Local\DigUp-Windows-v1", out bool first);
        if (!first) { Shutdown(); return; }

        _settings = Settings.Load();
        _engine = new Engine(_settings);
        _panel = new MainWindow(_engine, _settings);
        _panel.Hide();

        MakeTray();
        RegisterHotkey();
        _watcher = new FileSystemWatcherRunner(_settings, () => _engine.RequestIndex());

        if (_settings.IsNew || !_settings.SetupDone)
        {
            // First run: set up once, then start. The window saves on close.
            var setup = new Onboarding(_settings, _engine);
            setup.Show();
            setup.Closed += (_, _) =>
            {
                RegisterHotkey();
                ResetWatcher();
                if (_settings.SetupDone)
                    _engine.ApplySettings();
                else
                    _tray?.ShowBalloonTip(8000, "DigUp",
                        "Finish the one-time setup to start searching (tray menu → Open search).",
                        WinForms.ToolTipIcon.Info);
            };
        }
        else
        {
            _engine.Start(); // first pass runs in the background, pausable from the tray
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _hotkey?.Dispose();
        if (_tray is not null) { _tray.Visible = false; _tray.Dispose(); }
        _watcher?.Dispose();
        _engine?.Dispose();
        _single?.Dispose();
        base.OnExit(e);
    }

    /// <summary>Loud note (tray balloon): errors the user must see.</summary>
    public void ShowNote(string text)
    {
        _tray?.ShowBalloonTip(8000, "DigUp", text, WinForms.ToolTipIcon.Warning);
    }

    private static string FirstLine(string s) => s.Split('\n')[0].Trim();

    public void TogglePanel()
    {
        if (_panel is null || _settings is null) return;
        if (!_settings.SetupDone)
        {
            // Setup isn't finished: opening search opens setup instead.
            var setup = new Onboarding(_settings, _engine!);
            setup.Show();
            setup.Activate();
            setup.Closed += (_, _) =>
            {
                RegisterHotkey();
                ResetWatcher();
                if (_settings.SetupDone)
                    _engine?.ApplySettings();
            };
            return;
        }
        if (_panel.IsVisible) _panel.Hide();
        else { _panel.ApplyLook(); _panel.Show(); _panel.Activate(); _panel.FocusQuery(); }
    }

    private void MakeTray()
    {
        _tray = new WinForms.NotifyIcon
        {
            Text = "DigUp: search your files by meaning",
            Icon = AppIcon.Tray,
            Visible = true,
        };
        var menu = new WinForms.ContextMenuStrip();
        menu.Items.Add("Open search", null, (_, _) => TogglePanel());
        var pause = new WinForms.ToolStripMenuItem("Pause indexing") { CheckOnClick = true };
        pause.CheckedChanged += (_, _) => _engine?.SetPaused(pause.Checked);
        menu.Items.Add(pause);
        menu.Items.Add("Settings…", null, (_, _) => OpenSettings());
        menu.Items.Add("Quit DigUp", null, (_, _) => Shutdown());
        _tray.ContextMenuStrip = menu;
        _tray.DoubleClick += (_, _) => TogglePanel();
        _tray.BalloonTipTitle = "DigUp";
    }

    private void OpenSettings()
    {
        if (_settings is null || _engine is null) return;
        var win = new SettingsWindow(_settings);
        if (win.ShowDialog() == true)
        {
            RegisterHotkey();
            ResetWatcher();
            _engine.ApplySettings();
        }
    }

    private void ResetWatcher()
    {
        if (_settings is null || _engine is null) return;
        _watcher?.Dispose();
        _watcher = new FileSystemWatcherRunner(_settings, () => _engine.RequestIndex());
    }

    private void RegisterHotkey()
    {
        if (_settings is null) return;
        // Thread-wide hotkey (no window needed): WM_HOTKEY lands in this
        // thread's queue and is picked up below.
        _hotkey?.Dispose();
        _hotkey = new Hotkey();
        if (!_hotkey.Register(_settings.Hotkey))
            _tray?.ShowBalloonTip(5000, "DigUp",
                $"Hotkey {_settings.Hotkey} is taken by another app. Change it in Settings.", WinForms.ToolTipIcon.Warning);
        else if (_settings.Hotkey.Contains("shift") && _settings.Hotkey.Contains("alt"))
            _tray?.ShowBalloonTip(5000, "DigUp",
                "That hotkey uses Shift+Alt, which Windows also uses to switch input language. Ctrl+Alt+Space is safe.",
                WinForms.ToolTipIcon.Warning);
        if (!_hotkeyHooked)
        {
            _hotkeyHooked = true;
            ComponentDispatcher.ThreadPreprocessMessage += (ref MSG msg, ref bool handled) =>
            {
                const int WM_HOTKEY = 0x0312;
                if (msg.message == WM_HOTKEY) TogglePanel();
            };
        }
    }
}
