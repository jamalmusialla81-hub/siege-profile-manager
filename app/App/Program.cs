using Avalonia;

namespace SPM.App;

internal static class Program
{
    static Mutex? _single;

    [STAThread]
    public static int Main(string[] args)
    {
        _single = new Mutex(true, "SiegeProfileManager.SingleInstance", out bool first);
        if (!first) return 0;                                           // already running: the tray icon / F8 opens it
        try
        {
            return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        }
        finally { _single.ReleaseMutex(); }
    }

    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<App>().UsePlatformDetect();
}
