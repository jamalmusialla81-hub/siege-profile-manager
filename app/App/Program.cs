using System.Runtime.InteropServices;
using Avalonia;

namespace SPM.App;

internal static class Program
{
    static Mutex? _single;
    public static EventWaitHandle? ShowSignal;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int MessageBoxW(IntPtr h, string text, string caption, uint type);

    [STAThread]
    public static int Main(string[] args)
    {
        try
        {
            ShowSignal = new EventWaitHandle(false, EventResetMode.AutoReset, "SiegeProfileManager.Show");
            _single = new Mutex(true, "SiegeProfileManager.SingleInstance", out bool first);
            if (!first)
            {
                ShowSignal.Set();                                       // already running (probably in the tray): ask it to open its window
                if (OperatingSystem.IsWindows()) MessageBoxW(IntPtr.Zero, "Siege Profile Manager is already running (look for its icon in the system tray, or press F8). Opening its window now.", "Siege Profile Manager", 0x40);
                return 0;
            }
            return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        }
        catch (Exception e)
        {
            string path = "";
            try
            {
                var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SiegeProfileManager");
                Directory.CreateDirectory(dir);
                path = Path.Combine(dir, "crash.log");
                File.WriteAllText(path, DateTime.Now + "\n" + e);
            }
            catch { }
            if (OperatingSystem.IsWindows()) MessageBoxW(IntPtr.Zero, "Siege Profile Manager could not start:\n\n" + e.Message + "\n\nDetails: " + path, "Siege Profile Manager", 0x10);
            return 1;
        }
    }

    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<App>().UsePlatformDetect();
}
