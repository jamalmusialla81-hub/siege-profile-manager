using System.Diagnostics;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using SPM.Core;

namespace SPM.App;

public partial class MainWindow : Window
{
    readonly App _app;
    bool _loading;
    string _page = "Home";
    T C<T>(string n) where T : Control => this.FindControl<T>(n)!;

    public MainWindow(App app)
    {
        _app = app;
        AvaloniaXamlLoader.Load(this);

        C<Button>("NavHome").Click += (_, _) => Show("Home");
        C<Button>("NavOps").Click += (_, _) => Show("Ops");
        C<Button>("NavCoach").Click += (_, _) => Show("Coach");
        C<Button>("NavSettings").Click += (_, _) => Show("Settings");
        C<Button>("NavDiag").Click += (_, _) => Show("Diag");
        C<Button>("QuitBtn").Click += (_, _) => _app.Quit();
        C<Button>("CopyBtn").Click += async (_, _) => await CopyScript();
        C<Button>("FolderBtn").Click += (_, _) => OpenFolder(_app.Sync.MergedPath, true);
        C<Button>("CopyReportBtn").Click += async (_, _) => await SetClipboard(Report.Build(_app));
        C<Button>("DataFolderBtn").Click += (_, _) => OpenFolder(_app.Store.Dir, false);
        C<Button>("BrowseBtn").Click += async (_, _) => await Browse();

        var barrel = C<ComboBox>("BarrelBox"); barrel.ItemsSource = new[] { "AUTO", "SUPPRESSOR", "COMPENSATOR", "FLASH HIDER", "MUZZLE BRAKE", "EXTENDED BARREL", "NONE" };
        var grip = C<ComboBox>("GripBox"); grip.ItemsSource = new[] { "AUTO", "HORIZONTAL", "VERTICAL", "ANGLED", "NONE" };

        LoadSettings();
        InitPages();
        Hook(C<NumericUpDown>("DpiBox"), v => _app.Store.Config.Game.Dpi = v);
        Hook(C<NumericUpDown>("SensHBox"), v => _app.Store.Config.Game.SensH = v);
        Hook(C<NumericUpDown>("SensVBox"), v => _app.Store.Config.Game.SensV = v);
        Hook(C<NumericUpDown>("FovBox"), v => _app.Store.Config.Game.Fov = v);
        Hook(C<NumericUpDown>("AdsBox"), v => _app.Store.Config.Game.Ads = v);
        Hook(C<NumericUpDown>("ResWBox"), v => _app.Store.Config.Game.ResW = (int)v);
        Hook(C<NumericUpDown>("ResHBox"), v => _app.Store.Config.Game.ResH = (int)v);
        barrel.SelectionChanged += (_, _) => { if (!_loading && barrel.SelectedItem is string s) { _app.Store.Config.Prefs.Barrel = s; _app.Store.Touch(); } };
        grip.SelectionChanged += (_, _) => { if (!_loading && grip.SelectedItem is string s) { _app.Store.Config.Prefs.Grip = s; _app.Store.Touch(); } };
        C<TextBox>("LuaPathBox").LostFocus += (_, _) => SetLuaPath(C<TextBox>("LuaPathBox").Text ?? "");
        Check("AutoWriteChk", v => _app.Store.Config.AutoWriteLua = v);
        Check("HudChk", v => { _app.Store.Config.HudVisible = v; _app.ApplyHud(); });
        Check("SlotChk", v => _app.Store.Config.SlotSyncEnabled = v);
        Check("SlotAnyChk", v => _app.Store.Config.SlotSyncAnywhere = v);

        Closing += (_, e) => { e.Cancel = true; Hide(); };           // the app keeps running (HUD + link); F8 / tray icon reopens
    }

    void Hook(NumericUpDown box, Action<double> set) =>
        box.ValueChanged += (_, e) => { if (_loading || e.NewValue == null) return; set((double)e.NewValue.Value); _app.Store.Touch(); };

    void Check(string name, Action<bool> set)
    {
        var chk = C<CheckBox>(name);
        chk.IsCheckedChanged += (_, _) => { if (_loading) return; set(chk.IsChecked == true); _app.Store.Touch(); };
    }

    void LoadSettings()
    {
        _loading = true;
        var c = _app.Store.Config;
        C<NumericUpDown>("DpiBox").Value = (decimal)c.Game.Dpi;
        C<NumericUpDown>("SensHBox").Value = (decimal)c.Game.SensH;
        C<NumericUpDown>("SensVBox").Value = (decimal)c.Game.SensV;
        C<NumericUpDown>("FovBox").Value = (decimal)c.Game.Fov;
        C<NumericUpDown>("AdsBox").Value = (decimal)c.Game.Ads;
        C<NumericUpDown>("ResWBox").Value = c.Game.ResW;
        C<NumericUpDown>("ResHBox").Value = c.Game.ResH;
        C<ComboBox>("BarrelBox").SelectedItem = c.Prefs.Barrel;
        C<ComboBox>("GripBox").SelectedItem = c.Prefs.Grip;
        C<TextBox>("LuaPathBox").Text = c.LuaPath;
        C<CheckBox>("AutoWriteChk").IsChecked = c.AutoWriteLua;
        C<CheckBox>("HudChk").IsChecked = c.HudVisible;
        C<CheckBox>("SlotChk").IsChecked = c.SlotSyncEnabled;
        C<CheckBox>("SlotAnyChk").IsChecked = c.SlotSyncAnywhere;
        _loading = false;
    }

    void SetLuaPath(string path)
    {
        path = path.Trim().Trim('"');
        _app.Store.Config.LuaPath = path;
        _app.Store.Touch();
    }

    async Task Browse()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Choose siege_profile_manager.lua", AllowMultiple = false,
            FileTypeFilter = new[] { new FilePickerFileType("Lua script") { Patterns = new[] { "*.lua" } } },
        });
        var p = files.Count > 0 ? files[0].TryGetLocalPath() : null;
        if (p == null) return;
        C<TextBox>("LuaPathBox").Text = p;
        SetLuaPath(p);
    }

    async Task SetClipboard(string text)
    {
        var clip = GetTopLevel(this)?.Clipboard;
        if (clip != null) await clip.SetTextAsync(text);
    }

    async Task CopyScript()
    {
        var script = _app.Sync.BuildFullScript(out var err);
        if (script == null) { C<TextBlock>("CopyMsg").Text = "⚠ " + err; return; }
        await SetClipboard(script);
        C<TextBlock>("CopyMsg").Text = "✓ Copied. In G HUB open your script, select all, paste, and save. The same text is in the merged file.";
    }

    static void OpenFolder(string path, bool select)
    {
        try
        {
            if (select && File.Exists(path)) Process.Start(new ProcessStartInfo("explorer.exe", "/select,\"" + path + "\"") { UseShellExecute = true });
            else Process.Start(new ProcessStartInfo("explorer.exe", "\"" + Path.GetDirectoryName(path == "" ? "." : (Directory.Exists(path) ? path + "\\x" : path)) + "\"") { UseShellExecute = true });
        }
        catch { }
    }

    public void ShowPage(string name) => Show(name.ToLowerInvariant() switch { "settings" => "Settings", "diag" or "diagnostics" => "Diag", "ops" or "operators" => "Ops", "coach" => "Coach", _ => "Home" });

    void Show(string page)
    {
        _page = page;
        C<Control>("PageHome").IsVisible = page == "Home";
        C<Control>("PageOps").IsVisible = page == "Ops";
        C<Control>("PageCoach").IsVisible = page == "Coach";
        C<Control>("PageSettings").IsVisible = page == "Settings";
        C<Control>("PageDiag").IsVisible = page == "Diag";
        foreach (var (name, p) in new[] { ("NavHome", "Home"), ("NavOps", "Ops"), ("NavCoach", "Coach"), ("NavSettings", "Settings"), ("NavDiag", "Diag") })
        {
            var b = C<Button>(name);
            if (page == p) b.Classes.Add("on"); else b.Classes.Remove("on");
        }
        Refresh();
    }

    static string Att(Slot? s) => s == null ? "" : string.Join("  ·  ", new[] { s.Scope, s.Barrel, s.Grip }.Select(x => string.IsNullOrEmpty(x) ? "-" : x));

    public void Refresh()
    {
        if (!IsVisible) return;
        var live = _app.Live;
        var st = live.Status;
        var link = C<TextBlock>("LinkText");
        link.Text = st switch
        {
            LinkStatus.Connected => "● CONNECTED",
            LinkStatus.Idle => "● CONNECTED  ·  idle " + (int)live.AgeSeconds + " s",
            LinkStatus.Lost => "● SIGNAL LOST",
            LinkStatus.Mismatch => "● PROTOCOL MISMATCH",
            _ => "● WAITING FOR G HUB",
        };
        link.Foreground = new SolidColorBrush(Color.Parse(st is LinkStatus.Connected or LinkStatus.Idle ? "#4ADE9C" : st == LinkStatus.Waiting ? "#F2B84B" : "#F07178"));

        if (_page == "Home")
        {
            bool has = live.HasData;
            var op = Operators.Find(live.Get("operator")) ?? live.Get("operator", "");
            C<TextBlock>("OpText").Text = has ? op.ToUpperInvariant() : "—";
            C<TextBlock>("SideText").Text = has ? (live.Get("side").ToUpperInvariant().Contains("DEF") ? "Defence" : "Attack") + " side   ·   system " + (live.Get("enabled") == "1" ? "ON" : "OFF") : "Press RALT + left click on an operator tile once";
            bool prim = live.Get("slot", "PRIMARY").ToUpperInvariant() == "PRIMARY";
            C<TextBlock>("PrimText").Text = has ? (prim ? "►  " : "    ") + "Primary   " + live.Get("primary", "-") : "";
            C<TextBlock>("SecText").Text = has ? (!prim ? "►  " : "    ") + "Secondary   " + live.Get("secondary", "-") : "";
            C<TextBlock>("PrimAtt").Text = has ? "      " + string.Join("  ·  ", new[] { "primary_scope", "primary_barrel", "primary_grip" }.Select(k => live.Get(k, "-"))) : "";
            C<TextBlock>("SecAtt").Text = has ? "      " + string.Join("  ·  ", new[] { "secondary_scope", "secondary_barrel", "secondary_grip" }.Select(k => live.Get(k, "-"))) : "";
            C<TextBlock>("SyncText").Text = _app.Sync.StateText();
            var lua = _app.Store.Config.LuaPath;
            C<TextBlock>("SyncFile").Text = lua == "" ? "Lua file not found: choose it under Settings" : "Lua file: " + lua + (_app.Sync.LastWriteTime == DateTime.MinValue ? "" : "   (updated " + _app.Sync.LastWriteTime.ToString("HH:mm:ss") + ")");
            var list = C<ListBox>("RecentList");
            list.ItemsSource = live.Recent.AsEnumerable().Reverse().Take(30).Select(e => e.ToString()).ToList();
        }
        else if (_page == "Ops") RefreshOps();
        else if (_page == "Coach") RefreshCoach();
        else if (_page == "Diag")
        {
            var box = C<TextBox>("ReportBox");
            var text = Report.Build(_app);
            if (box.Text != text) box.Text = text;
        }
        else if (_page == "Settings")
        {
            var lua = _app.Store.Config.LuaPath;
            C<TextBlock>("LuaPathMsg").Text = lua == "" ? "No Lua file chosen yet" : File.Exists(lua) ? "✓ file found" : "⚠ that file does not exist";
        }
    }
}
