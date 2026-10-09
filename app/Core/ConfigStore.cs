using System.Text.Json;
using System.Text.Json.Nodes;

namespace SPM.Core;

/// <summary>Loads and saves the app config (debounced), and imports the old AutoHotkey config once.</summary>
[System.Text.Json.Serialization.JsonSourceGenerationOptions(WriteIndented = true, PropertyNamingPolicy = System.Text.Json.Serialization.JsonKnownNamingPolicy.CamelCase)]
[System.Text.Json.Serialization.JsonSerializable(typeof(AppConfig))]
internal partial class ConfigJson : System.Text.Json.Serialization.JsonSerializerContext { }

public sealed class ConfigStore : IDisposable
{

    readonly object _gate = new();
    System.Threading.Timer? _timer;
    public string Dir { get; }
    public string FilePath => Path.Combine(Dir, "app-config.json");
    public AppConfig Config { get; private set; } = new();
    public string LastError { get; private set; } = "";
    public bool ImportedFromAhk { get; private set; }

    /// <summary>Raised (on a worker thread) after the config changed.</summary>
    public event Action? Changed;
    /// <summary>Raised after a successful write to disk.</summary>
    public event Action? Saved;

    public ConfigStore(string? dir = null)
    {
        Dir = dir ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SiegeProfileManager");
        Directory.CreateDirectory(Dir);
    }

    public static string DefaultDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SiegeProfileManager");

    public void Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                Config = JsonSerializer.Deserialize(File.ReadAllText(FilePath), ConfigJson.Default.AppConfig) ?? new AppConfig();
            }
            else
            {
                var ahk = Path.Combine(Dir, "config.json");
                if (File.Exists(ahk)) { try { Config = AhkImport.Read(ahk); ImportedFromAhk = true; } catch (Exception e) { LastError = "AHK import failed: " + e.Message; } }
            }
        }
        catch (Exception e)
        {
            LastError = "config unreadable (" + e.Message + "), using defaults";
            try { File.Copy(FilePath, FilePath + ".damaged", true); } catch { }
            Config = new AppConfig();
        }
        SeedStandard();
        Normalize();
        Touch();
    }

    /// <summary>Standard weapon choices, written once into the saved loadouts (a saved loadout beats the Lua's built-in default).</summary>
    void SeedStandard()
    {
        if (Config.SeededStandard) return;
        Config.Saved["Mute"] = new Loadout { Primary = new Slot { Weapon = "M590A1" }, Secondary = new Slot { Weapon = "SMG-11" } };
        Config.Saved["Warden"] = new Loadout { Primary = new Slot { Weapon = "M590A1" }, Secondary = new Slot { Weapon = "SMG-12" } };
        Config.SeededStandard = true;
    }

    void Normalize()
    {
        if (Config.Side != "defenders") Config.Side = "attackers";
        if (Config.Game.ResW < 640 || Config.Game.ResH < 480) { Config.Game.ResW = 1920; Config.Game.ResH = 1080; }
        if (Config.Game.Dpi <= 0) Config.Game.Dpi = 1600;
        if (Config.Game.SensH <= 0) Config.Game.SensH = 4;
        if (Config.Game.SensV <= 0) Config.Game.SensV = 4;
    }

    /// <summary>Call after any change: saves shortly after and tells the listeners.</summary>
    public void Touch()
    {
        lock (_gate)
        {
            _timer?.Dispose();
            _timer = new System.Threading.Timer(_ => SaveNow(), null, 800, System.Threading.Timeout.Infinite);
        }
        Changed?.Invoke();
    }

    public void SaveNow()
    {
        lock (_gate)
        {
            try
            {
                var tmp = FilePath + ".tmp";
                File.WriteAllText(tmp, JsonSerializer.Serialize(Config, ConfigJson.Default.AppConfig));
                if (File.Exists(FilePath)) File.Copy(FilePath, FilePath + ".bak", true);
                File.Move(tmp, FilePath, true);
                LastError = "";
            }
            catch (Exception e) { LastError = "save failed: " + e.Message; return; }
        }
        Saved?.Invoke();
    }

    public void Dispose() { lock (_gate) { _timer?.Dispose(); _timer = null; } SaveNow(); }
}

/// <summary>Reads the old SiegeOverlay.ahk config.json (calibration, saved loadouts, learned profiles, settings).</summary>
public static class AhkImport
{
    static double D(JsonNode? n, double def)
    {
        if (n is JsonValue v)
        {
            if (v.TryGetValue<double>(out var d)) return d;
            if (v.TryGetValue<string>(out var s) && double.TryParse(s, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var p)) return p;
        }
        return def;
    }
    static string S(JsonNode? n, string def = "") => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : (n is JsonValue v2 ? v2.ToString() : def);

    static Slot? ReadSlot(JsonNode? n)
    {
        if (n is not JsonObject o) return null;
        var w = S(o["weapon"]);
        if (w == "") return null;
        return new Slot { Weapon = w, Scope = S(o["scope"]), Barrel = S(o["barrel"]), Grip = S(o["grip"]) };
    }

    static Loadout ReadLoadout(JsonNode? n) => new() { Primary = ReadSlot(n?["primary"]), Secondary = ReadSlot(n?["secondary"]) };

    public static AppConfig Read(string path)
    {
        var root = JsonNode.Parse(File.ReadAllText(path)) as JsonObject ?? throw new InvalidDataException("not an object");
        var c = new AppConfig();
        if (root["game"] is JsonObject g)
        {
            c.Game.Dpi = D(g["dpi"], c.Game.Dpi); c.Game.SensH = D(g["sensH"], c.Game.SensH); c.Game.SensV = D(g["sensV"], c.Game.SensV);
            c.Game.Fov = D(g["fov"], c.Game.Fov); c.Game.Ads = D(g["ads"], c.Game.Ads);
            c.Game.ResW = (int)D(g["resW"], c.Game.ResW); c.Game.ResH = (int)D(g["resH"], c.Game.ResH);
        }
        if (root["prefs"] is JsonObject p)
        {
            c.Prefs.Scope = S(p["scope"], "AUTO"); c.Prefs.Barrel = S(p["barrel"], "SUPPRESSOR"); c.Prefs.Grip = S(p["grip"], "HORIZONTAL");
        }
        if (root["state"] is JsonObject st) { c.Side = S(st["side"], "attackers"); c.Operator = S(st["operator"]); }
        if (root["favorites"] is JsonArray fa) foreach (var f in fa) c.Favorites.Add(S(f));
        if (root["saved"] is JsonObject sv) foreach (var kv in sv) c.Saved[kv.Key] = ReadLoadout(kv.Value);
        if (root["loadouts"] is JsonObject lo)
            foreach (var kv in lo)
            {
                var set = new NamedLoadoutSet { Active = S(kv.Value?["active"]) };
                if (kv.Value?["list"] is JsonArray la)
                    foreach (var e in la) set.List.Add(new NamedLoadout { Name = S(e?["name"]), Loadout = ReadLoadout(e) });
                c.Loadouts[kv.Key] = set;
            }
        if (root["calibration"] is JsonObject ca)
            foreach (var kv in ca)
                c.Calibration[kv.Key] = new Calibration { Tlx = D(kv.Value?["tlx"], 0), Tly = D(kv.Value?["tly"], 0), Brx = D(kv.Value?["brx"], 0), Bry = D(kv.Value?["bry"], 0), Src = S(kv.Value?["src"], "lua") };
        if (root["luaKeybinds"] is JsonObject kb)
            foreach (var kv in kb) c.LuaKeybinds[kv.Key] = new KeyBind { Mod = S(kv.Value?["mod"]), Button = (int)D(kv.Value?["button"], 0) };
        if (root["learned"] is JsonObject le)
            foreach (var kv in le)
                c.Learned[kv.Key] = new LearnedProfile
                {
                    R = D(kv.Value?["r"], 0), Y1 = D(kv.Value?["y1"], 0), Y2 = D(kv.Value?["y2"], 0), Tym1 = D(kv.Value?["tym1"], 500), Tym2 = D(kv.Value?["tym2"], 900),
                    Side = D(kv.Value?["side"], 0), Strength = D(kv.Value?["strength"], 1), Late = D(kv.Value?["late"], 1),
                };
        if (root["lua"] is JsonObject lu) c.LuaPath = S(lu["path"]);
        return c;
    }
}
