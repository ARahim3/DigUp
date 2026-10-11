// Search overlay: dimmed + blurred screen behind, crisp card in front.
// Type, arrows, Enter opens (PDF at page, code at line, sound/video note
// their moment), Esc or backdrop click hides. The preview shows a thumbnail
// for pictures and video frames, words for documents and code.

using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;

namespace DigUp.App;

public partial class MainWindow : Window
{
    private readonly Engine _engine;
    private readonly Settings _settings;
    private readonly System.Timers.Timer _debounce = new(180) { AutoReset = false };
    private List<Engine.Hit> _hits = [];
    private bool _big;
    private int _searchGen; // only the newest background search may touch the list
    private PreviewWindow? _preview;
    // Mac rule: once arrows/click moved the selection, Space previews
    // instead of typing a space. Any edit (or a click back in the field)
    // hands Space back to typing.
    private bool _navigated;

    public MainWindow(Engine engine, Settings settings)
    {
        _engine = engine; _settings = settings;
        InitializeComponent();
        try { Icon = AppIcon.Wpf; } catch { }
        _engine.Changed += () => Dispatcher.Invoke(() => Status.Text = _engine.Status);
        Status.Text = _engine.Status;
        _debounce.Elapsed += (_, _) => Dispatcher.Invoke(SearchNow);
        Query.TextChanged += (_, _) => { _navigated = false; _debounce.Stop(); _debounce.Start(); };
        Query.PreviewKeyDown += OnKey;
        Query.PreviewMouseLeftButtonDown += (_, _) => _navigated = false;
        Results.MouseDoubleClick += (_, _) => OpenSelected();
        Results.PreviewMouseLeftButtonDown += (_, _) => _navigated = true;
        Results.SelectionChanged += (_, _) => { ShowPreview(); FollowPreview(); };
        Results.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Space) { TogglePreview(); e.Handled = true; }
        };
        Loaded += (_, _) => FadeIn();
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        TryBlurBehind();
    }

    // Blurred screen behind the window (Windows acrylic), lighter than full
    // frosted glass so text stays readable. If it fails, the dark dim
    // rectangle still carries the look. Never throws.
    private void TryBlurBehind()
    {
        ApplyLook();
    }

    /// <summary>Dim + blur from Settings, applied every time the panel opens.</summary>
    public void ApplyLook()
    {
        try
        {
            DimRect.Opacity = Math.Clamp(_settings.Dim, 0, 0.8);
            var hwnd = new WindowInteropHelper(this).Handle;
            if (hwnd == IntPtr.Zero) return;
            var accent = new AccentPolicy
            {
                AccentState = _settings.Blur ? 4 /* acrylic */ : 0 /* off */,
                AccentFlags = 0,
                // Blur only, (almost) no tint: the Dim slider alone decides
                // darkness. A black tint here used to double-darken everything.
                GradientColor = 0x02000000,
                AnimationId = 0,
            };
            var data = new WindowCompositionAttributeData
            {
                Attribute = 19 /* accent policy */,
                Data = Marshal.AllocHGlobal(Marshal.SizeOf<AccentPolicy>()),
                SizeOfData = Marshal.SizeOf<AccentPolicy>(),
            };
            try
            {
                Marshal.StructureToPtr(accent, data.Data, false);
                SetWindowCompositionAttribute(hwnd, ref data);
            }
            finally { Marshal.FreeHGlobal(data.Data); }
        }
        catch { }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct AccentPolicy
    {
        public int AccentState;
        public int AccentFlags;
        public uint GradientColor;
        public int AnimationId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WindowCompositionAttributeData
    {
        public int Attribute;
        public IntPtr Data;
        public int SizeOfData;
    }

    [DllImport("user32.dll")]
    private static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref WindowCompositionAttributeData data);

    private void FadeIn()
    {
        var anim = new DoubleAnimation(0, 1, new Duration(TimeSpan.FromMilliseconds(130)));
        Root.BeginAnimation(OpacityProperty, anim);
    }

    public void FocusQuery()
    {
        Query.Focus();
        Query.SelectAll();
    }

    private void OnBackdrop(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is System.Windows.Shapes.Rectangle) Hide();
    }

    // The query box never waits: each keystroke starts a background search,
    // and only the newest one paints (older ones throw their work away).
    private void SearchNow()
    {
        string q = Query.Text.Trim();
        if (q.Length == 0) { Results.ItemsSource = null; ShowPreview(); return; }
        int gen = Interlocked.Increment(ref _searchGen);
        Task.Run(() =>
        {
            List<Engine.Hit> hits;
            try { hits = _engine.Search(q, limit: 30); }
            catch (Exception ex)
            {
                Dispatcher.Invoke(() =>
                {
                    if (gen == _searchGen)
                    {
                        ErrorLog.Write("search: " + ex);
                        Status.Text = "search stopped: " + ex.Message.Split('\n')[0];
                    }
                });
                return;
            }
            Dispatcher.Invoke(() =>
            {
                if (gen != _searchGen) return; // a newer keystroke won
                _hits = hits;
                Results.ItemsSource = _hits.Select(h => new
                {
                    Title = Short(h.Path) + (h.Where.Length > 0 ? "  " + h.Where : ""),
                    Detail = h.Kind + (h.Excerpt is null ? "" : " — " + h.Excerpt),
                }).ToList();
                if (_hits.Count > 0) Results.SelectedIndex = 0;
                ShowPreview();
            });
        });
    }

    private void ShowPreview()
    {
        if (Results.SelectedIndex < 0 || Results.SelectedIndex >= _hits.Count)
        {
            PreviewBox.Visibility = Visibility.Collapsed;
            return;
        }
        PreviewBox.Visibility = Visibility.Visible;
        var h = _hits[Results.SelectedIndex];
        PreviewTitle.Text = Short(h.Path, 90) + (h.Where.Length > 0 ? "  " + h.Where : "");
        PreviewKind.Text = KindText(h);
        PreviewText.Text = h.Excerpt ?? "(no words — found by what it shows or says)";
        PreviewImage.Source = null;
        // Thumbnails load off the UI thread; a late one for an old selection is dropped.
        int at = Results.SelectedIndex;
        Task.Run(() => ThumbFor(h))?.ContinueWith(t =>
        {
            if (t.Result is null || at != Results.SelectedIndex) return;
            Dispatcher.Invoke(() =>
            {
                if (at != Results.SelectedIndex) return;
                try
                {
                    var bmp = new BitmapImage();
                    bmp.BeginInit();
                    bmp.CacheOption = BitmapCacheOption.OnLoad;
                    bmp.DecodePixelWidth = 440;
                    bmp.UriSource = new Uri(t.Result);
                    bmp.EndInit();
                    bmp.Freeze();
                    PreviewImage.Source = bmp;
                }
                catch { }
            });
        });
    }

    private static string? ThumbFor(Engine.Hit h)
    {
        try
        {
            return h.Kind switch
            {
                "Image" or "Screenshot" => Thumbs.ForImage(h.Path),
                "Video" => Thumbs.ForVideo(h.Path, ParseSeconds(h.Where)),
                _ => null,
            };
        }
        catch { return null; }
    }

    private static string KindText(Engine.Hit h) => h.Kind switch
    {
        "Video" or "Audio" => $"{h.Kind} · plays from {h.Where}",
        "Pdf" => $"PDF · page {h.Where.TrimStart('@')}",
        "Code" => $"Code · {h.Where}",
        _ => h.Kind,
    };

    private void OnKey(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            // Esc closes the preview first, then the panel (like the Mac).
            if (_preview is not null) { try { _preview.Close(); } catch { } }
            else Hide();
            e.Handled = true;
        }
        else if (e.Key == Key.Enter) { OpenSelected(); e.Handled = true; }
        else if (e.Key == Key.Space && _navigated) { TogglePreview(); e.Handled = true; }
        else if (e.Key == Key.Down && Results.Items.Count > 0)
        { Results.SelectedIndex = Math.Min(Results.SelectedIndex + 1, Results.Items.Count - 1); Results.ScrollIntoView(Results.SelectedItem); _navigated = true; e.Handled = true; }
        else if (e.Key == Key.Up && Results.Items.Count > 0)
        { Results.SelectedIndex = Math.Max(Results.SelectedIndex - 1, 0); Results.ScrollIntoView(Results.SelectedItem); _navigated = true; e.Handled = true; }
        else if (e.Key == Key.O && Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
        { _big = !_big; Card.Width = _big ? 980 : 680; e.Handled = true; }
        else if (e.Key == Key.C && Keyboard.Modifiers.HasFlag(ModifierKeys.Control) && Results.SelectedIndex >= 0)
        {
            try { System.Windows.Clipboard.SetFileDropList([.. _hits.Where((_, i) => i == Results.SelectedIndex).Select(x => x.Path)]); }
            catch { }
        }
    }

    /// <summary>Space: show the selected file itself, or hide it again.</summary>
    private void TogglePreview()
    {
        try
        {
            if (_preview is not null) { _preview.Close(); return; }
            if (Results.SelectedIndex < 0 || Results.SelectedIndex >= _hits.Count) return;
            var win = new PreviewWindow(
                System.IO.Path.Combine(AppContext.BaseDirectory, "pdfium.dll"), OpenSelected);
            win.Owner = this;
            win.Closed += (_, _) => { if (ReferenceEquals(_preview, win)) _preview = null; };
            _preview = win;
            win.ShowHit(_hits[Results.SelectedIndex]);
            win.Show();
            win.Focus();
        }
        catch (Exception ex)
        {
            Status.Text = "can't preview it: " + ex.Message.Split('\n')[0].Trim();
        }
    }

    /// <summary>The open preview follows the selection, like Quick Look.</summary>
    private void FollowPreview()
    {
        if (_preview is null) return;
        try
        {
            if (Results.SelectedIndex < 0 || Results.SelectedIndex >= _hits.Count) _preview.Close();
            else _preview.ShowHit(_hits[Results.SelectedIndex]);
        }
        catch { try { _preview.Close(); } catch { } }
    }

    private void OnOpenButton(object sender, RoutedEventArgs e) => OpenSelected();

    private void Complain(string what, Exception ex)
    {
        string msg = $"{what}: {ex.Message.Split('\n')[0].Trim()}";
        Status.Text = msg;
        // Status lines are easy to miss: balloon it too. Never silent.
        if (System.Windows.Application.Current is App app) app.ShowNote(msg);
    }

    private void OnShowButton(object sender, RoutedEventArgs e)
    {
        if (Results.SelectedIndex < 0 || Results.SelectedIndex >= _hits.Count) return;
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe",
                $"/select,\"{_hits[Results.SelectedIndex].Path.Replace('/', '\\')}\"") { UseShellExecute = true });
            Hide(); // Explorer opens below us otherwise: we cover the whole screen.
        }
        catch (Exception ex) { Complain("can't show it", ex); }
    }

    private void OnCopyButton(object sender, RoutedEventArgs e)
    {
        if (Results.SelectedIndex < 0 || Results.SelectedIndex >= _hits.Count) return;
        try { System.Windows.Clipboard.SetFileDropList([.. _hits.Where((_, i) => i == Results.SelectedIndex).Select(x => x.Path)]); }
        catch (Exception ex) { Complain("can't copy it", ex); }
    }

    private void OpenSelected()
    {
        if (Results.SelectedIndex < 0 || Results.SelectedIndex >= _hits.Count) return;
        var h = _hits[Results.SelectedIndex];
        try
        {
            if (h.Kind == "Code")
            {
                int line = h.Where.StartsWith("lines ") ? ParseLine(h.Where) : 1;
                var t = Editors.ForCode(_settings.Editor, h.Path, line);
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(t.Exe, t.Args) { UseShellExecute = true });
            }
            else if (h.Kind == "Pdf") Editors.OpenPdf(h.Path, ParsePage(h.Where));
            else Editors.Open(h.Path);
            Hide(); // the opened app would land behind our fullscreen overlay
        }
        catch (Exception ex) { Complain($"can't open {Short(h.Path, 60)}", ex); }
    }

    internal static int ParseLine(string where)
    {
        var digits = new string(where.SkipWhile(c => !char.IsDigit(c)).TakeWhile(c => char.IsDigit(c)).ToArray());
        return int.TryParse(digits, out int n) ? Math.Max(1, n) : 1;
    }

    internal static double? ParsePage(string where)
    {
        var digits = new string(where.SkipWhile(c => !char.IsDigit(c)).TakeWhile(c => char.IsDigit(c) || c == '.').ToArray());
        return double.TryParse(digits, out double n) ? n : null;
    }

    internal static double ParseSeconds(string where)
    {
        var digits = new string(where.SkipWhile(c => !char.IsDigit(c)).TakeWhile(c => char.IsDigit(c) || c == '.' || c == ':').ToArray());
        if (digits.Contains(':') && TimeSpan.TryParse("0:" + digits, out var ts)) return ts.TotalSeconds;
        return double.TryParse(digits, out double n) ? n : 0;
    }

    private static string Short(string p, int max = 80) => p.Length > max ? "…" + p[^Math.Max(1, max - 1)..] : p;

    protected override void OnClosed(EventArgs e)
    {
        try { _preview?.Close(); } catch { }
        _preview = null;
        _debounce.Dispose();
        base.OnClosed(e);
    }
}
