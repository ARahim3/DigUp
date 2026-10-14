// First-run setup: folders → code → model download → done. One window,
// plain words, Back works everywhere, Cancel only stops the download.

using System.Windows;

namespace DigUp.App;

public partial class Onboarding : Window
{
    private readonly Settings _settings;
    private readonly Engine _engine;
    private int _step;
    private CancellationTokenSource? _dl;
    private bool _downloaded;
    /// <summary>True when the user pressed through to the end (not X).</summary>
    public bool Completed { get; private set; }

    public Onboarding(Settings settings, Engine engine)
    {
        _settings = settings;
        _engine = engine;
        InitializeComponent();
        try { Icon = AppIcon.Wpf; } catch { }
        RefreshFolders();
        Show(0);
    }

    private void Show(int step)
    {
        _step = step;
        P0.Visibility = step == 0 ? Visibility.Visible : Visibility.Collapsed;
        P1.Visibility = step == 1 ? Visibility.Visible : Visibility.Collapsed;
        P2.Visibility = step == 2 ? Visibility.Visible : Visibility.Collapsed;
        P3.Visibility = step == 3 ? Visibility.Visible : Visibility.Collapsed;
        P4.Visibility = step == 4 ? Visibility.Visible : Visibility.Collapsed;
        Step.Text = $"Step {Math.Min(step + 1, 5)} of 5";
        Back.IsEnabled = step is 1 or 2;
        Next.Content = step == 3 ? "Download" : step == 4 ? "Open search" : "Next";
        if (step == 1) UpdateEstimate();
        if (step == 3 && !_downloaded) StartDownload();
    }

    private void OnBack(object sender, RoutedEventArgs e) => Show(_step - 1);

    private void OnNext(object sender, RoutedEventArgs e)
    {
        if (_step == 1 && _settings.Folders.Count == 0)
        {
            System.Windows.MessageBox.Show(this, "Pick at least one folder first.", "DigUp setup",
                System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Information);
            return;
        }
        if (_step == 2) _settings.Code = Code.IsChecked == true;
        if (_step == 3 && !_downloaded) return; // downloading; Next becomes Next after
        if (_step == 4) { _settings.SetupDone = true; Completed = true; Close(); return; }
        Show(_step + 1);
    }

    private void RefreshFolders()
    {
        Folders.ItemsSource = null;
        Folders.ItemsSource = _settings.Folders.ToList();
    }

    private void OnAdd(object sender, RoutedEventArgs e)
    {
        using var dlg = new FolderBrowserDialog { Description = "Pick a folder for DigUp to search" };
        if (dlg.ShowDialog() == System.Windows.Forms.DialogResult.OK &&
            !_settings.Folders.Contains(dlg.SelectedPath, StringComparer.OrdinalIgnoreCase))
        {
            _settings.Folders.Add(dlg.SelectedPath);
            RefreshFolders();
            UpdateEstimate();
        }
    }

    private void OnRemove(object sender, RoutedEventArgs e)
    {
        if (Folders.SelectedItem is string s)
        {
            _settings.Folders.Remove(s);
            RefreshFolders();
            UpdateEstimate();
        }
    }

    private void UpdateEstimate()
    {
        Estimate.Text = "estimating…";
        var folders = _settings.Folders.ToList();
        Task.Run(() =>
        {
            try
            {
                var (n, seconds, _) = Engine.Estimate(folders, false);
                Dispatcher.Invoke(() => Estimate.Text =
                    n == 0 ? "nothing to read there." : $"{n} files, about {Friendly(seconds)} for the first pass.");
            }
            catch { Dispatcher.Invoke(() => Estimate.Text = ""); }
        });
    }

    private void StartDownload()
    {
        Next.IsEnabled = false;
        _dl = new CancellationTokenSource();
        var progress = new Progress<(string File, double Frac)>(t =>
            Dispatcher.Invoke(() =>
            {
                Bar.Value = t.Frac * 100;
                DlStatus.Text = $"{t.File}: {t.Frac * 100:0}%";
            }));
        Task.Run(async () =>
        {
            try
            {
                await _engine.EnsureModelsAsync(progress, _dl.Token);
                await Dispatcher.InvokeAsync(() =>
                {
                    _downloaded = true;
                    Bar.Value = 100;
                    DlStatus.Text = "model ready.";
                    Next.IsEnabled = true;
                    Next.Content = "Next";
                });
            }
            catch (OperationCanceledException)
            {
                await Dispatcher.InvokeAsync(() => { DlStatus.Text = "stopped."; Next.IsEnabled = true; });
            }
            catch (Exception ex)
            {
                await Dispatcher.InvokeAsync(() =>
                {
                    DlStatus.Text = "couldn't download: " + ex.Message.Split('\n')[0] + " Try again with Next.";
                    Next.IsEnabled = true;
                });
            }
        });
    }

    protected override void OnClosed(EventArgs e)
    {
        _dl?.Cancel();
        _settings.Save();
        base.OnClosed(e);
    }

    private static string Friendly(double seconds)
    {
        if (seconds < 60) return $"{seconds:0} s";
        if (seconds < 3600) return $"{seconds / 60:0} min";
        return $"{seconds / 3600:0.0} h";
    }
}
