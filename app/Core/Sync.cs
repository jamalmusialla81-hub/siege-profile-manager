using System.Globalization;
using System.Text;

namespace SPM.Core;

public enum SyncState { Unknown, Ok, Pending, Old, NoBlock }

/// <summary>Keeps the config in step with the Lua (state + events) and produces / writes the merged Lua script.</summary>
public sealed class SyncService
{
    readonly ConfigStore _store;
    readonly LiveState _live;
    string _lastBody = "";
    string _lastBase = "";
    /// <summary>Operators whose loadout was edited in the app: the Lua's old loadout must not overwrite the edit before the new script is pasted.</summary>
    public HashSet<string> Held { get; } = new();
    public string LastError { get; private set; } = "";
    public DateTime LastWriteTime { get; private set; } = DateTime.MinValue;

    AppConfig C => _store.Config;
    public string MergedPath => Path.Combine(_store.Dir, "siege_profile_manager.merged.lua");
    public string LivePath => Path.Combine(_store.Dir, "spm_live.lua");
    public DateTime LiveWriteTime { get; private set; } = DateTime.MinValue;
    string _lastLiveBody = "";

    public SyncService(ConfigStore store, LiveState live)
    {
        _store = store;
        _live = live;
        live.StateReceived += OnState;
        live.EventReceived += OnEvent;
        LuaBlock.LivePath = LivePath;
        store.Saved += () => { WriteLive(); AutoWrite(); };
    }

    // ---- config <-> Lua baseline ---------------------------------------------------------------
    public bool Pending => C.Baseline != LuaBlock.ContentHash(C);
    void Rebase() => C.Baseline = LuaBlock.ContentHash(C);

    /// <summary>A change that came FROM the Lua (it already has it): if we were in sync before, stay in sync.</summary>
    void FromLua(Func<bool> change)
    {
        bool was = !Pending;
        if (!change()) return;
        if (was) Rebase();
        _store.Touch();
    }

    public SyncState State()
    {
        if (!_live.HasData) return SyncState.Unknown;
        var rev = _live.Get("cfgrev", "none");
        if (rev == "none") return SyncState.NoBlock;
        if (rev != C.CopiedRev) return SyncState.Old;
        return Pending ? SyncState.Pending : SyncState.Ok;
    }

    /// <summary>Saves a loadout chosen in the app (reaches the Lua when the new script is pasted).</summary>
    public void EditLoadout(string op, Loadout lo)
    {
        C.Saved[op] = lo;
        Held.Add(op);
        _store.Touch();
    }

    public void SetFavourite(string op, bool on)
    {
        bool has = C.Favorites.Contains(op);
        if (on && !has) C.Favorites.Add(op);
        else if (!on && has) C.Favorites.Remove(op);
        else return;
        _store.Touch();
    }

    public string StateText() => State() switch
    {
        SyncState.Ok => "In sync: the Lua in G HUB has your latest config",
        SyncState.Pending => _live.Get("live") == "ok" ? "Sending live..." : "New changes: copy the script and paste it into G HUB",
        SyncState.Old => _live.Get("live") == "ok"
            ? "Sent live: G HUB picks it up on your next shot or key press"
            : "G HUB has an older config: copy the script and paste it again",
        SyncState.NoBlock => "G HUB has no config yet: copy the script and paste it into G HUB",
        _ => "Waiting for G HUB",
    };

    // ---- state / events from the Lua -----------------------------------------------------------
    static string Clean(string v) => v == "-" ? "" : v;

    Slot? ReadSlot(string kind)
    {
        var w = _live.Get(kind, "NONE");
        if (w is "NONE" or "-" or "") return null;
        return new Slot { Weapon = w, Scope = Clean(_live.Get(kind + "_scope")), Barrel = Clean(_live.Get(kind + "_barrel")), Grip = Clean(_live.Get(kind + "_grip")) };
    }

    void OnState()
    {
        var op = Operators.Find(_live.Get("operator"));
        if (op == null) return;
        var side = _live.Get("side").ToUpperInvariant().Contains("DEF") ? "defenders" : "attackers";
        var lo = new Loadout { Primary = ReadSlot("primary"), Secondary = ReadSlot("secondary") };
        FromLua(() =>
        {
            bool changed = false;
            if (C.Side != side || C.Operator != op) { C.Side = side; C.Operator = op; changed = true; }
            if (State() == SyncState.Ok) Held.Clear();
            if (C.StartOperator != "" && C.StartOperator == op) { C.StartOperator = ""; changed = true; }
            if (Held.Contains(op) && C.Saved.TryGetValue(op, out var held) && held.Same(lo)) Held.Remove(op);
            if (!Held.Contains(op) && (!C.Saved.TryGetValue(op, out var cur) || !cur.Same(lo))) { C.Saved[op] = lo; changed = true; }
            // grids the Lua already has (calibrated in game before this app existed)
            foreach (var sd in new[] { "attackers", "defenders" })
            {
                var t = _live.Get("cal_" + sd, "-");
                if (t != "-" && !C.Calibration.ContainsKey(sd) && TryCal(t, out var cal)) { C.Calibration[sd] = cal; changed = true; }
            }
            return changed;
        });
    }

    static bool TryCal(string text, out Calibration cal)
    {
        cal = new Calibration();
        var p = text.Split(',');
        if (p.Length != 4) return false;
        var v = new double[4];
        for (int i = 0; i < 4; i++)
            if (!double.TryParse(p[i], NumberStyles.Float, CultureInfo.InvariantCulture, out v[i])) return false;
        cal = new Calibration { Tlx = v[0], Tly = v[1], Brx = v[2], Bry = v[3], Src = "lua" };
        return true;
    }

    static string SideOf(string label) => label.ToUpperInvariant().Contains("DEF") ? "defenders" : "attackers";

    void OnEvent(Packet e)
    {
        var type = e.Get("type");
        switch (type)
        {
            case "favourite_changed":
                {
                    var name = Operators.Find(e.Get("operator"));
                    if (name == null) break;
                    bool on = e.Get("on") == "1";
                    FromLua(() =>
                    {
                        bool has = C.Favorites.Contains(name);
                        if (on && !has) { C.Favorites.Add(name); return true; }
                        if (!on && has) { C.Favorites.Remove(name); return true; }
                        return false;
                    });
                    _live.AddRecent((on ? "★ Favourited " : "Unfavourited ") + name);
                    break;
                }
            case "calibration_complete":
                {
                    var side = SideOf(e.Get("side"));
                    if (double.TryParse(e.Get("tlx"), NumberStyles.Float, CultureInfo.InvariantCulture, out var a)
                        && double.TryParse(e.Get("tly"), NumberStyles.Float, CultureInfo.InvariantCulture, out var b)
                        && double.TryParse(e.Get("brx"), NumberStyles.Float, CultureInfo.InvariantCulture, out var c2)
                        && double.TryParse(e.Get("bry"), NumberStyles.Float, CultureInfo.InvariantCulture, out var d))
                        FromLua(() => { C.Calibration[side] = new Calibration { Tlx = a, Tly = b, Brx = c2, Bry = d, Src = "lua" }; return true; });
                    _live.AddRecent("Calibrated " + side);
                    break;
                }
            case "calibration_reset":
                {
                    var side = SideOf(e.Get("side"));
                    FromLua(() => C.Calibration.Remove(side));
                    _live.AddRecent("Calibration reset " + side);
                    break;
                }
            case "operator_changed": _live.AddRecent("Operator → " + e.Get("operator", "?")); break;
            case "weapon_changed": _live.AddRecent(e.Get("slot", "").ToUpperInvariant() + " weapon → " + e.Get("weapon", "?")); break;
            case "attachment_changed": _live.AddRecent(e.Get("field", "").ToUpperInvariant() + " → " + e.Get("value", "?")); break;
            case "slot_changed": _live.AddRecent("Slot → " + e.Get("slot", "").ToUpperInvariant()); break;
            case "side_changed": _live.AddRecent("Side → " + SideOf(e.Get("side"))); break;
            case "loadout_changed": _live.AddRecent("Loadout → " + e.Get("name", "?")); break;
            case "system_enabled": _live.AddRecent("System enabled"); break;
            case "system_disabled": _live.AddRecent("System disabled"); break;
        }
    }

    // ---- the Lua script on disk ----------------------------------------------------------------
    /// <summary>The latest Lua script, carried inside the app. When set, every merge starts from it (never from an old file on disk).</summary>
    public Func<string?>? BundledScript { get; set; }

    /// <summary>Version string of the bundled script ("" when unknown).</summary>
    public string ExpectedLuaVersion()
    {
        var t = BundledScript?.Invoke();
        if (t == null) return "";
        var m = System.Text.RegularExpressions.Regex.Match(t, "SPM_LUA_VERSION\\s*=\\s*\"([^\"]+)\"");
        return m.Success ? m.Groups[1].Value : "";
    }

    /// <summary>"" when G HUB runs the bundled script, else a sentence saying it is outdated.</summary>
    public string LuaVersionProblem()
    {
        if (!_live.HasData) return "";
        var want = ExpectedLuaVersion();
        if (want == "") return "";
        var have = _live.Get("luaver", "");
        return have == want ? "" : (have == "" ? "G HUB is running an OLD script (no version). " : $"G HUB is running script {have}, this app has {want}. ")
            + "Press Copy script and paste it into G HUB.";
    }

    string? BaseScript(out string error)
    {
        error = "";
        var bundled = BundledScript?.Invoke();
        if (!string.IsNullOrEmpty(bundled)) return bundled;
        var path = FindLua();
        if (path == null) { error = "Lua script not found: choose it in Settings"; return null; }
        try { return File.ReadAllText(path, Encoding.UTF8); }
        catch (Exception ex) { error = "cannot read the Lua script: " + ex.Message; return null; }
    }

    public string? FindLua()
    {
        if (C.LuaPath != "" && File.Exists(C.LuaPath)) return C.LuaPath;
        foreach (var dir in new[] { AppContext.BaseDirectory, Directory.GetCurrentDirectory() })
        {
            var p = Path.Combine(dir, "siege_profile_manager.lua");
            if (File.Exists(p)) { C.LuaPath = p; _store.Touch(); return p; }
        }
        return null;
    }

    static string NewRev() => DateTime.Now.ToString("yyyyMMddHHmmss", CultureInfo.InvariantCulture);

    /// <summary>The complete script with your config merged in, also saved as the merged file. Marks the config as handed over.</summary>
    public string? BuildFullScript(out string error)
    {
        var text = BaseScript(out error);
        if (text == null) return null;
        var rev = NewRev();
        var merged = LuaBlock.Merge(text, C, rev, out error);
        if (merged == null) return null;
        try { File.WriteAllText(MergedPath, merged, new UTF8Encoding(false)); } catch (Exception ex) { LastError = "merged file: " + ex.Message; }
        C.CopiedRev = rev;
        Rebase();
        _store.Touch();
        return merged;
    }

    /// <summary>
    /// Writes the live config file (atomic replace) whenever the config really changed. The G HUB script reads it with loadfile, so
    /// no paste is needed. The file counts as "handed over": the rev inside it becomes the expected rev.
    /// </summary>
    public void WriteLive(bool force = false)
    {
        try
        {
            var body = LuaBlock.Build(C, "0");
            if (!force && body == _lastLiveBody && File.Exists(LivePath)) return;
            var rev = NewRev();
            var text = LuaBlock.BuildLive(C, rev);
            var tmp = LivePath + ".tmp";
            File.WriteAllText(tmp, text, new UTF8Encoding(false));
            File.Move(tmp, LivePath, true);
            _lastLiveBody = body;
            LiveWriteTime = DateTime.Now;
            C.CopiedRev = rev;
            Rebase();
        }
        catch (Exception ex) { LastError = "live file: " + ex.Message; }
    }

    /// <summary>After every config save: keep the SPM_USER block inside the Lua file on disk current (only when it really changed).</summary>
    public void AutoWrite()
    {
        if (!C.AutoWriteLua) return;
        try
        {
            if (C.LuaPath == "") return;
            var dir = Path.GetDirectoryName(C.LuaPath);
            if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return;
            var body = LuaBlock.Build(C, "0");
            var bundled = BundledScript?.Invoke();
            string? baseText = !string.IsNullOrEmpty(bundled) ? bundled : (File.Exists(C.LuaPath) ? File.ReadAllText(C.LuaPath, Encoding.UTF8) : null);
            if (baseText == null) return;
            if (body == _lastBody && !string.IsNullOrEmpty(_lastBase) && _lastBase == baseText.Length.ToString()) return;
            var merged = LuaBlock.Merge(baseText, C, NewRev(), out var err);
            if (merged == null) { LastError = err; return; }
            if (File.Exists(C.LuaPath) && !File.Exists(C.LuaPath + ".bak"))
                File.Copy(C.LuaPath, C.LuaPath + ".bak");                       // keep the very first file you had
            File.WriteAllText(C.LuaPath, merged, new UTF8Encoding(false));
            File.WriteAllText(MergedPath, merged, new UTF8Encoding(false));
            _lastBody = body;
            _lastBase = baseText.Length.ToString();
            LastWriteTime = DateTime.Now;
            LastError = "";
            _live.AddLog("Lua file on disk updated with the current config");
        }
        catch (Exception ex) { LastError = ex.Message; }
    }
}
