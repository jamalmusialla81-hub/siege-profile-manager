using System.Text;
using SPM.Core;

namespace SPM.App;

public static class Report
{
    static string Row(string k, string v) => k.PadRight(22) + v + "\n";

    public static string Build(App app)
    {
        var live = app.Live; var cfg = app.Store.Config; var sync = app.Sync;
        var t = new StringBuilder();
        t.Append("SIEGE PROFILE MANAGER 3.0 - DIAGNOSTICS\n\n");
        t.Append("LINK\n");
        t.Append(Row("G HUB LINK", live.Status.ToString().ToUpperInvariant() + (live.AgeSeconds >= 0 ? $"  (last packet {live.AgeSeconds:0.0} s ago)" : "")));
        t.Append(Row("PROTOCOL", live.Protocol == 0 ? "-" : "v" + live.Protocol));
        t.Append(Row("SESSION", live.Session == "" ? "-" : live.Session));
        t.Append(Row("PACKETS", $"{live.Ok} ok / {live.Rejected} rejected / {live.Duplicates} duplicate / {live.Restarts} restart(s)"));
        t.Append(Row("DEBUG CHANNEL", app.Dbwin.Ready ? (app.Dbwin.Shared ? "ready, but another debug monitor is running" : "ready") : "NOT AVAILABLE: " + app.Dbwin.Error));
        t.Append("\nGAME (from the Lua)\n");
        t.Append(Row("OPERATOR", live.Get("operator", "-")));
        t.Append(Row("SIDE", live.Get("side", "-")));
        t.Append(Row("SLOT", live.Get("slot", "-") + "  (keys 1/2 -> " + app.Hooks.Slot + ")"));
        t.Append(Row("PRIMARY", live.Get("primary", "-") + "   " + string.Join(" · ", new[] { "primary_scope", "primary_barrel", "primary_grip" }.Select(k => live.Get(k, "-")))));
        t.Append(Row("SECONDARY", live.Get("secondary", "-") + "   " + string.Join(" · ", new[] { "secondary_scope", "secondary_barrel", "secondary_grip" }.Select(k => live.Get(k, "-")))));
        t.Append(Row("RECOIL", live.Get("recoil", "-")));
        t.Append(Row("RECOIL PROFILE", live.Get("recoil_profile", "-")));
        t.Append(Row("SYSTEM", live.Get("enabled") == "1" ? "ON" : "OFF"));
        t.Append(Row("CALIBRATION", live.Get("calibration", "-")));
        t.Append(Row("LAST BURST", live.Get("spray", "-")));
        t.Append(Row("LAST SKIP", live.Get("ev_skip", "-")));
        t.Append("\nCONFIG\n");
        t.Append(Row("CONFIG BLOCK (Lua)", "rev " + live.Get("cfgrev", "-")));
        t.Append(Row("SYNC", sync.State() + ": " + sync.StateText()));
        t.Append(Row("LUA SCRIPT VERSION", $"G HUB runs {(live.Get("luaver", "") == "" ? "an OLD script" : live.Get("luaver"))}, this app has {sync.ExpectedLuaVersion()}" + (sync.LuaVersionProblem() == "" ? "  (match)" : "  <-- OUTDATED")));
        t.Append(Row("G HUB LUA API", live.Get("api", "- (update the script to see it)")));
        t.Append(Row("LUA FILE", cfg.LuaPath == "" ? "not found: choose it in Settings" : cfg.LuaPath));
        t.Append(Row("AUTO-WRITE", cfg.AutoWriteLua ? "on" + (sync.LastWriteTime == DateTime.MinValue ? "" : ", last " + sync.LastWriteTime.ToString("HH:mm:ss")) : "off"));
        t.Append(Row("RESOLUTION", $"{cfg.Game.ResW} x {cfg.Game.ResH}   dpi {cfg.Game.Dpi}   sens {cfg.Game.SensH}/{cfg.Game.SensV}"));
        t.Append(Row("SAVED LOADOUTS", cfg.Saved.Count + " operators, " + cfg.Favorites.Count + " favourites, " + cfg.Learned.Count + " learned profiles"));
        t.Append(Row("CALIBRATION GRIDS", string.Join(", ", cfg.Calibration.Keys.DefaultIfEmpty("none"))));
        t.Append(Row("COACH", (app.Coach.Training ? "TRAINING ON" : "training off") + $"  measured {app.Coach.Measured}, skipped {app.Coach.Skipped}"));
        t.Append(Row("  LAST", app.Coach.Last));
        t.Append(Row("  STATUS", app.Coach.Status));
        t.Append(Row("  PX PER COUNT", app.Coach.Calibrated ? $"vertical {cfg.Coach.PxY}, horizontal {cfg.Coach.PxX}" : "not calibrated (assuming 0.4)"));
        t.Append(Row("FOREGROUND", Native.ForegroundExe() == "" ? "-" : Native.ForegroundExe()));
        t.Append(Row("LAST ERROR", new[] { app.Store.LastError, sync.LastError }.FirstOrDefault(e => e != "") ?? "none"));
        t.Append("\nLOG\n");
        foreach (var e in live.Log.AsEnumerable().Reverse().Take(60)) t.Append(e + "\n");
        return t.ToString();
    }
}
