// Quick Look for Windows: Space shows the selected file itself — a picture
// full-size, a PDF at the matched page, sound/video playing from the
// moment, code around the matched lines — and follows the selection while
// open, like the Mac panel. Space/Esc closes, Enter opens. Never throws.

using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;

namespace DigUp.App;

public partial class PreviewWindow : Window
{
    private readonly string _pdfiumDll;
    private readonly Action _open;
    private string? _tempPng;
    private double _moment;
    private System.Windows.Threading.DispatcherTimer? _clock;

    public PreviewWindow(string pdfiumDll, Action open)
    {
        _pdfiumDll = pdfiumDll;
        _open = open;
        InitializeComponent();
        try { Icon = AppIcon.Wpf; } catch { }
        KeyDown += (_, e) =>
        {
            if (e.Key is Key.Escape or Key.Space) { Close(); e.Handled = true; }
            else if (e.Key == Key.Enter) { _open(); e.Handled = true; }
        };
        Player.MediaOpened += (_, _) =>
        {
            try
            {
                if (_moment > 0 && _moment < Player.NaturalDuration.TimeSpan.TotalSeconds)
                    Player.Position = TimeSpan.FromSeconds(_moment);
                Player.Play();
                PlayPause.Content = "Pause";
            }
            catch { }
        };
        Player.MediaFailed += (_, _) =>
        {
            Words.Text = "(this file won't play here — Enter opens it in its own app)";
            Words.Visibility = Visibility.Visible;
            WordsScroll.Visibility = Visibility.Visible;
            Player.Visibility = Visibility.Collapsed;
            Transport.Visibility = Visibility.Collapsed;
        };
        Closed += (_, _) => Cleanup();
    }

    /// <summary>Show another hit (follows the panel's selection).</summary>
    public void ShowHit(Engine.Hit hit, string query = "")
    {
        Cleanup();
        ResetViews();
        Title.Text = hit.Path + (hit.Where.Length > 0 ? "  " + hit.Where : "");
        Kind.Text = KindLine(hit);
        try
        {
            switch (PreviewContent.For(hit, _pdfiumDll, query))
            {
                case PreviewModel.Image img:
                    ShowPicture(img.Path, temp: false);
                    break;
                case PreviewModel.TempImage tmp:
                    ShowPicture(tmp.Path, temp: true);
                    break;
                case PreviewModel.Media m:
                    ShowMedia(m);
                    break;
                case PreviewModel.Text t:
                    ShowWords(t.Body, mono: hit.Kind == "Code", at: t.Highlight, length: t.HighlightLength);
                    break;
                case PreviewModel.None n:
                    ShowWords(n.Note, mono: false, at: -1, length: 0);
                    break;
            }
        }
        catch
        {
            ShowWords("(can't preview this — Enter opens it in its own app)", mono: false, at: -1, length: 0);
        }
    }

    private void ResetViews()
    {
        Picture.Visibility = Visibility.Collapsed;
        Player.Visibility = Visibility.Collapsed;
        Words.Visibility = Visibility.Collapsed;
        WordsScroll.Visibility = Visibility.Collapsed;
        Transport.Visibility = Visibility.Collapsed;
    }

    private void ShowPicture(string path, bool temp)
    {
        if (temp) _tempPng = path;
        var bmp = new BitmapImage();
        bmp.BeginInit();
        bmp.CacheOption = BitmapCacheOption.OnLoad;
        bmp.DecodePixelWidth = 1400;
        bmp.UriSource = new Uri(path);
        bmp.EndInit();
        bmp.Freeze();
        Picture.Source = bmp;
        Picture.Visibility = Visibility.Visible;
    }

    private void ShowMedia(PreviewModel.Media m)
    {
        _moment = m.Seconds;
        Player.Visibility = m.IsVideo ? Visibility.Visible : Visibility.Collapsed;
        Transport.Visibility = Visibility.Visible;
        Time.Text = m.IsVideo ? "" : $"sound · from {Stamp(m.Seconds)}";
        try
        {
            Player.Source = new Uri(m.Path);
            // Position applies in MediaOpened (the file isn't ready before).
        }
        catch
        {
            Words.Text = "(this file won't play here — Enter opens it in its own app)";
            Words.Visibility = Visibility.Visible;
            WordsScroll.Visibility = Visibility.Visible;
            Player.Visibility = Visibility.Collapsed;
        }
        StartClock();
    }

    private void ShowWords(string body, bool mono, int at, int length)
    {
        Words.FontFamily = new System.Windows.Media.FontFamily(
            mono ? "Cascadia Mono, Consolas, Courier New" : "Segoe UI");
        Words.TextWrapping = mono ? TextWrapping.NoWrap : TextWrapping.Wrap;
        Words.Text = body;
        Words.Visibility = Visibility.Visible;
        WordsScroll.Visibility = Visibility.Visible;
        // Jump to the relevant passage and mark it.
        if (at >= 0 && at < body.Length && length > 0)
        {
            try
            {
                Words.Select(at, Math.Min(length, body.Length - at));
                Words.ScrollToLine(Words.GetLineIndexFromCharacterIndex(at));
            }
            catch { }
        }
    }

    private static string KindLine(Engine.Hit h) => h.Kind switch
    {
        "Video" or "Audio" => $"{h.Kind} · plays from {Stamp(MainWindow.ParseSeconds(h.Where))}",
        "Pdf" => $"PDF · page {(int)(MainWindow.ParsePage(h.Where) ?? 1)}",
        "Code" => $"Code · {h.Where}",
        _ => h.Kind,
    };

    private static string Stamp(double seconds)
    {
        int s = Math.Max(0, (int)Math.Round(seconds));
        return $"{s / 60}:{s % 60:D2}";
    }

    private void StartClock()
    {
        StopClock();
        _clock = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        _clock.Tick += (_, _) =>
        {
            try
            {
                if (Player.Source is not null && Player.NaturalDuration.HasTimeSpan)
                    Time.Text = $"{Stamp(Player.Position.TotalSeconds)} / {Stamp(Player.NaturalDuration.TimeSpan.TotalSeconds)}";
            }
            catch { }
        };
        _clock.Start();
    }

    private void StopClock() { try { _clock?.Stop(); } catch { } _clock = null; }

    private void OnPlayPause(object sender, RoutedEventArgs e)
    {
        try
        {
            // No CanPause/IsPlaying flag exists: keep our own from the label.
            bool playing = (string)PlayPause.Content == "Pause";
            if (playing) Player.Pause(); else Player.Play();
            PlayPause.Content = playing ? "Play" : "Pause";
        }
        catch { }
    }

    private void OnOpen(object sender, RoutedEventArgs e) => _open();

    private void OnClose(object sender, RoutedEventArgs e) => Close();

    private void Cleanup()
    {
        StopClock();
        try { Player.Stop(); } catch { }
        try { Player.Source = null; } catch { }
        try { Player.Close(); } catch { }
        Picture.Source = null;
        if (_tempPng is not null)
        {
            try { File.Delete(_tempPng); } catch { }
            _tempPng = null;
        }
    }
}
