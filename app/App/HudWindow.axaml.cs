using Avalonia;
using Avalonia.Controls;
using Avalonia.Markup.Xaml;
using Avalonia.Media;
using SPM.Core;

namespace SPM.App;

public partial class HudWindow : Window
{
    readonly App _app;
    T C<T>(string n) where T : Control => this.FindControl<T>(n)!;

    public HudWindow(App app)
    {
        _app = app;
        AvaloniaXamlLoader.Load(this);
        Opened += (_, _) =>
        {
            var h = TryGetPlatformHandle()?.Handle ?? IntPtr.Zero;
            Native.MakeOverlay(h);
            Place();
        };
    }

    void Place()
    {
        var scr = Screens.Primary;
        if (scr == null) return;
        var wa = scr.WorkingArea;
        double scale = scr.Scaling;
        Position = new PixelPoint(wa.Right - (int)((Width + 24) * scale), wa.Y + (int)(24 * scale));
    }

    static string Att(Slot? s) => s == null ? "" : $"{Or(s.Scope)}  ·  {Or(s.Barrel)}  ·  {Or(s.Grip)}";
    static string Or(string v) => string.IsNullOrEmpty(v) ? "-" : v;

    public void Refresh()
    {
        if (!IsVisible) return;
        Opacity = _app.Store.Config.HudOpacity;
        var live = _app.Live;
        var cfg = _app.Store.Config;
        bool has = live.HasData;
        var op = Operators.Find(live.Get("operator")) ?? live.Get("operator", "");
        C<TextBlock>("Op").Text = has ? op.ToUpperInvariant() : "WAITING FOR G HUB";
        C<TextBlock>("Side").Text = has ? (live.Get("side").ToUpperInvariant().Contains("DEF") ? "DEFENCE" : "ATTACK") + "   ·   " + live.Get("slot", "PRIMARY").ToLowerInvariant() + " slot" : "start the G HUB script";
        bool prim = live.Get("slot", "PRIMARY").ToUpperInvariant() == "PRIMARY";
        C<TextBlock>("Prim").Text = has ? (prim ? "►  " : "    ") + live.Get("primary", "-") : "";
        C<TextBlock>("Sec").Text = has ? (!prim ? "►  " : "    ") + live.Get("secondary", "-") : "";
        C<TextBlock>("PrimAtt").Text = has ? "      " + string.Join("  ·  ", new[] { "primary_scope", "primary_barrel", "primary_grip" }.Select(k => Or(live.Get(k)))) : "";
        C<TextBlock>("SecAtt").Text = has ? "      " + string.Join("  ·  ", new[] { "secondary_scope", "secondary_barrel", "secondary_grip" }.Select(k => Or(live.Get(k)))) : "";
        var st = live.Status;
        C<TextBlock>("Dot").Foreground = new SolidColorBrush(Color.Parse(st == LinkStatus.Connected || st == LinkStatus.Idle ? "#4ADE9C" : st == LinkStatus.Waiting ? "#F2B84B" : "#F07178"));
        C<TextBlock>("Status").Text = _app.Sync.StateText();
    }
}
