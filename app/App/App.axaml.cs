using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;
using SPM.Core;

namespace SPM.App;

public partial class App : Application
{
    public ConfigStore Store { get; private set; } = null!;
    public LiveState Live { get; } = new();
    public SyncService Sync { get; private set; } = null!;
    public DbwinListener Dbwin { get; } = new();
    public HookService Hooks { get; private set; } = null!;
    public SPM.Core.Coach.CoachService Coach { get; private set; } = null!;
    public RawMouse Raw { get; } = new();
    MainWindow _main = null!;
    HudWindow _hud = null!;

    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            Store = new ConfigStore();
            Store.Load();
            Sync = new SyncService(Store, Live);
            Sync.FindLua();

            Dbwin.Message += (_, text) => Dispatcher.UIThread.Post(() => Live.Ingest(text));
            Dbwin.Start();

            Hooks = new HookService(Store);
            Raw.Start();
            Coach = new SPM.Core.Coach.CoachService(Store, Live)
            {
                ScreenSize = ScreenCapture.PrimarySize,
                Grab = ScreenCapture.Grab,
                Allowed = Hooks.SiegeActive,
                Raw = Raw,
                Keys = Hooks,
            };
            _main = new MainWindow(this);
            _hud = new HudWindow(this);
            Hooks.ToggleWindow += ToggleMain;
            Hooks.ToggleHud += () => { Store.Config.HudVisible = !Store.Config.HudVisible; Store.Touch(); ApplyHud(); };
            Hooks.SlotChanged += () => _hud.Refresh();
            Hooks.ToggleTraining += () => Coach.SetTraining(!Coach.Training);
            Hooks.CalBegin += () => { var m = Coach.BeginCalibration(); if (m != "") Live.AddLog("calibration: " + m); };
            Hooks.CalFinish += () => Coach.FinishCalibration();
            Hooks.Start();

            if (Store.ImportedFromAhk) Live.AddLog("Imported your settings from the old AutoHotkey config");
            if (Store.LastError != "") Live.AddLog(Store.LastError);
            if (!Dbwin.Ready) Live.AddLog("debug channel not available: " + Dbwin.Error);
            else if (Dbwin.Shared) Live.AddLog("another debug monitor (DebugView?) is running: close it");

            // test helpers: --feed <file> plays recorded packets into the link, --page <home|settings|diag> opens that page
            var argv = desktop.Args ?? Array.Empty<string>();
            int fi = Array.IndexOf(argv, "--feed");
            if (fi >= 0 && fi + 1 < argv.Length && File.Exists(argv[fi + 1])) Live.Ingest(File.ReadAllText(argv[fi + 1]));
            int pi = Array.IndexOf(argv, "--page");
            var startPage = pi >= 0 && pi + 1 < argv.Length ? argv[pi + 1] : "home";

            SetupTray(desktop);
            ApplyHud();
            _main.Show();
            _main.ShowPage(startPage);

            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
            timer.Tick += (_, _) => { _main.Refresh(); _hud.Refresh(); };
            timer.Start();
            desktop.Exit += (_, _) => { Hooks.Dispose(); Dbwin.Dispose(); Raw.Dispose(); Store.Dispose(); };
        }
        base.OnFrameworkInitializationCompleted();
    }

    void ToggleMain()
    {
        if (_main.IsVisible) _main.Hide(); else { _main.Show(); _main.Activate(); }
    }

    public void ApplyHud()
    {
        if (Store.Config.HudVisible) { if (!_hud.IsVisible) _hud.Show(); } else _hud.Hide();
    }

    public void Quit()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime d) d.Shutdown();
    }

    void SetupTray(IClassicDesktopStyleApplicationLifetime desktop)
    {
        try
        {
            var bmp = new WriteableBitmap(new PixelSize(32, 32), new Vector(96, 96), PixelFormat.Bgra8888, AlphaFormat.Premul);
            using (var fb = bmp.Lock())
            {
                var px = new byte[32 * 32 * 4];
                for (int y = 0; y < 32; y++)
                    for (int x = 0; x < 32; x++)
                    {
                        bool edge = x < 3 || y < 3 || x > 28 || y > 28;
                        int o = (y * 32 + x) * 4;
                        px[o] = edge ? (byte)0xE8 : (byte)0x13; px[o + 1] = edge ? (byte)0xC9 : (byte)0x16; px[o + 2] = edge ? (byte)0x4C : (byte)0x1D; px[o + 3] = 255;
                    }
                System.Runtime.InteropServices.Marshal.Copy(px, 0, fb.Address, px.Length);
            }
            var open = new NativeMenuItem("Open  (F8)");
            open.Click += (_, _) => { _main.Show(); _main.Activate(); };
            var exit = new NativeMenuItem("Exit");
            exit.Click += (_, _) => Quit();
            var tray = new TrayIcon { Icon = new WindowIcon(bmp), ToolTipText = "Siege Profile Manager", Menu = new NativeMenu { open, exit } };
            tray.Clicked += (_, _) => { _main.Show(); _main.Activate(); };
            TrayIcon.SetIcons(this, new TrayIcons { tray });
        }
        catch (Exception e) { Live.AddLog("tray icon failed: " + e.Message); }
    }
}
