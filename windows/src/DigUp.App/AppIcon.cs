// One icon everywhere: the exe, the windows, the tray. The art is the Mac
// logo (docs/logo.png) baked to Assets/DigUp.ico at 16/32/48/256 px.

using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace DigUp.App;

internal static class AppIcon
{
    private static ImageSource? _wpf;
    private static System.Drawing.Icon? _tray;

    public static ImageSource Wpf
    {
        get
        {
            if (_wpf is null)
            {
                using var s = ResourceStream();
                var frame = BitmapFrame.Create(s, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                frame.Freeze();
                _wpf = frame;
            }
            return _wpf;
        }
    }

    public static System.Drawing.Icon Tray
    {
        get
        {
            if (_tray is null)
            {
                using var s = ResourceStream();
                _tray = new System.Drawing.Icon(s, new System.Drawing.Size(16, 16));
            }
            return _tray;
        }
    }

    private static Stream ResourceStream()
    {
        var uri = new Uri("pack://application:,,,/Assets/DigUp.ico", UriKind.Absolute);
        var info = System.Windows.Application.GetResourceStream(uri);
        if (info is null) throw new InvalidOperationException("Assets/DigUp.ico is missing from the build.");
        return info.Stream;
    }
}
